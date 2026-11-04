// BlastSearchFile.swift - A BLAST search as a file in its result folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A BLAST search as a file in its result folder, `blast-search.json`.
///
/// The file is what makes a search survive a quit, a crash, a sleep and a move of its project. Its identity is
/// ``searchID`` and not an RID, and nothing after a saved reply knows where the reply came from
/// (ARCH-BLAST-RESILIENCE sections 1 and 8). It holds no reads, which stay in `query.fasta` beside it.
package struct BlastSearchFile: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1
    /// The file's name in the result folder.
    package static let fileName = "blast-search.json"
    /// The Put body as first built, which every send of the search repeats byte for byte.
    package static let formFileName = "put-form.txt"
    /// The folder under the result folder that holds each reply until the record is durable.
    package static let repliesFolderName = "replies"

    /// Which service answers the search.
    package enum Route: String, Codable, Sendable {
        case ncbi
    }

    /// Who this search talks to. A field here can only stop a contact and can never name a host (item 20).
    package enum Origin: String, Codable, Sendable {
        case ncbi
        case standIn
    }

    /// Where the search stands. A row's parked state is the row's and not the search's.
    package enum State: String, Codable, Sendable {
        /// The form is durable and NCBI has not accepted it.
        case sending
        /// A Put was lost after it went out, so nobody knows whether NCBI has it. One more Put settles that.
        case sendUnknown
        /// NCBI holds the search.
        case waiting
        /// NCBI said READY, and the reply is not yet a record.
        case fetching
        /// The record is durable.
        case done
        /// NCBI no longer holds the search.
        case expired
        /// NCBI said the search failed.
        case ncbiFailed
        /// NCBI accepted nothing.
        case notSent
        /// The person stopped it.
        case stopped

        /// Whether nothing more happens on its own.
        package var isEnding: Bool {
            switch self {
            case .sending, .sendUnknown, .waiting, .fetching: false
            case .done, .expired, .ncbiFailed, .notSent, .stopped: true
            }
        }
    }

    /// What made the request, so a resume judges the reply as the first process would have.
    package struct Facts: Codable, Sendable, Equatable {
        package var taxonName: String
        package var taxId: Int
        package var program: String
        package var database: String
        package var entrezQuery: String?
        package var maxTargetSeqs: Int
        package var eValueThreshold: Double
        package var extraArgs: String
        package var maxConcurrentSubmissions: Int
        package var sequenceMates: [String: Int]
        package var acceptedTaxIds: [Int]
        package var acceptedTaxonNames: [String]
        package var relatedTaxIds: [Int]
        package var relatedTaxonNames: [String]

        package init(_ request: BlastVerificationRequest) {
            self.taxonName = request.taxonName
            self.taxId = request.taxId
            self.program = request.program
            self.database = request.database
            self.entrezQuery = request.entrezQuery
            self.maxTargetSeqs = request.maxTargetSeqs
            self.eValueThreshold = request.eValueThreshold
            self.extraArgs = request.extraArgs
            self.maxConcurrentSubmissions = request.maxConcurrentSubmissions
            self.sequenceMates = request.sequenceMates
            self.acceptedTaxIds = request.acceptedTaxIds.sorted()
            self.acceptedTaxonNames = request.acceptedTaxonNames
            self.relatedTaxIds = request.relatedTaxIds.sorted()
            self.relatedTaxonNames = request.relatedTaxonNames
        }

        /// The request these facts made, with the sequences of the folder's `query.fasta`.
        package func request(sequences: [(id: String, sequence: String)]) -> BlastVerificationRequest {
            BlastVerificationRequest(
                taxonName: taxonName,
                taxId: taxId,
                sequences: sequences,
                program: program,
                database: database,
                entrezQuery: entrezQuery,
                maxTargetSeqs: maxTargetSeqs,
                eValueThreshold: eValueThreshold,
                extraArgs: extraArgs,
                maxConcurrentSubmissions: maxConcurrentSubmissions,
                sequenceMates: sequenceMates,
                acceptedTaxIds: Set(acceptedTaxIds),
                acceptedTaxonNames: acceptedTaxonNames,
                relatedTaxIds: Set(relatedTaxIds),
                relatedTaxonNames: relatedTaxonNames
            )
        }
    }

    /// One send of the search, with its own RID from NCBI.
    package struct Copy: Codable, Sendable, Equatable {
        package typealias Kind = BlastSubmissionKind

        package enum State: String, Codable, Sendable {
            case sending
            /// A Put was lost after it went out, so nobody knows whether NCBI has it. One more Put settles that.
            case sendUnknown
            case live
            case ready
            case expired
            case failed
            case notSent

            /// Whether this send can still bring an answer.
            package var isAlive: Bool {
                switch self {
                case .sending, .sendUnknown, .live: true
                case .ready, .expired, .failed, .notSent: false
                }
            }
        }

        package var ordinal: Int
        package var kind: Kind
        /// NCBI's request ID, nil until a Put is accepted and for a route that has none.
        package var rid: String?
        package var rtoe: Int?
        package var postAt: Date?
        package var state: State
        /// When the next contact of this send is due, a Put, a check or a fetch. Wall clock, so a sleep, a quit and a
        /// restart all read as contact now once it has passed.
        package var nextCheckAt: Date?
        package var lastCheckAt: Date?
        /// Every contact that brought no news, kept for the log. No count here ends anything.
        package var failedContacts: Int
        /// Failed contacts since the last answer.
        package var failedInARow: Int
        /// How many Puts NCBI answered with a busy status.
        package var busyAnswers: Int
        /// `Status=UNKNOWN` reads in a row past the grace.
        package var unknownInARow: Int
        package var readyAt: Date?
        /// What NCBI's `ThereAreHits` said on READY, nil when it did not say.
        package var thereAreHits: Bool?
        /// The saved reply's name under ``BlastSearchFile/repliesFolderName``.
        package var replyFile: String?
        /// Whether the saved reply could not be read, so the next tick fetches again.
        package var replyUnreadable: Bool
        /// Fetches that gave an answer, readable or not.
        package var fetchTries: Int
        /// NCBI's words, up to ``BlastSearchPolicy/wordsLimit`` bytes.
        package var words: String?
        /// Whether LGE's limit already counts the next POST of this send. A POST spends it before it goes out, and one
        /// that reached nothing gets it back, so a Mac with no network counts one send however long it tries.
        package var postReserved: Bool

        package init(ordinal: Int, kind: Kind, nextCheckAt: Date?) {
            self.ordinal = ordinal
            self.kind = kind
            self.state = .sending
            self.nextCheckAt = nextCheckAt
            self.failedContacts = 0
            self.failedInARow = 0
            self.busyAnswers = 0
            self.unknownInARow = 0
            self.replyUnreadable = false
            self.fetchTries = 0
            self.postReserved = false
        }
    }

    /// How a search ended, with the words a person reads.
    package struct Ending: Codable, Sendable, Equatable {
        package var state: State
        package var at: Date
        package var words: String
    }

    /// Why LGE's next own send is held back and until when. It stays due and never ends the search (item 7).
    package struct CopyHold: Codable, Sendable, Equatable {
        package enum Reason: String, Codable, Sendable {
            /// Two spent searches in a row paused every copy.
            case guardPause
            /// The hour's copies are all out.
            case copyCap
            /// LGE's limit on POSTed reads an hour is full.
            case hourlyLimit
            /// This Mac is past NCBI's searches in 24 hours.
            case dayCount
        }

        package var reason: Reason
        package var until: Date
    }

    package var schemaVersion: Int
    package var searchID: UUID
    package var route: Route
    package var origin: Origin
    package var createdAt: Date
    package var state: State
    /// The command that started the search, which a replay runs again.
    package var submitArgv: [String]
    package var facts: Facts
    package var query: BlastSubmissionRecord.Query
    /// Lower-case hex SHA-256 of `put-form.txt`.
    package var formSHA256: String
    package var copies: [Copy]
    package var winnerOrdinal: Int?
    package var spentAt: Date?
    package var guardStruck: Bool
    package var ending: Ending?
    /// Why the next copy is held, nil when none is. Words say so once for each change of reason.
    package var copyHold: CopyHold?

    package init(
        searchID: UUID = UUID(),
        origin: Origin,
        createdAt: Date,
        submitArgv: [String],
        facts: Facts,
        query: BlastSubmissionRecord.Query,
        formSHA256: String
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.searchID = searchID
        self.route = .ncbi
        self.origin = origin
        self.createdAt = createdAt
        self.state = .sending
        self.submitArgv = submitArgv
        self.facts = facts
        self.query = query
        self.formSHA256 = formSHA256
        self.copies = [Copy(ordinal: 1, kind: .first, nextCheckAt: createdAt)]
        self.guardStruck = false
    }

    /// The send that won, or the first when none has.
    package var winner: Copy {
        copies.first { $0.ordinal == winnerOrdinal } ?? copies[0]
    }
}

/// Every number a BLAST search keeps to, in this folder and nowhere else, so that the field log can move it.
package enum BlastSearchPolicy {
    /// A copy is due at search age k x this many seconds.
    package static let resendInterval: TimeInterval = 180
    /// Three sends in all, the first and two more.
    package static let maxCopies = 3
    /// A search READY younger than this says NCBI is answering, so the guard's count starts again. It is the age at
    /// which a search with all its sends out on time is spent.
    package static let cameBackInTimeAge: TimeInterval = resendInterval * Double(maxCopies)
    /// Spent searches in a row that pause every copy.
    package static let spentInARowThatPause = 2
    /// How long that pause lasts.
    package static let guardPause: TimeInterval = 3600
    /// The most copies in ``copyWindow`` across every process on this Mac.
    package static let maxCopiesAnHour = 4
    package static let copyWindow: TimeInterval = 3600
    /// Past this many POSTs in 24 hours LGE makes no automatic copy, and it never refuses a first send on this count.
    /// NCBI's page names the figure, and LGE's count may differ from NCBI's.
    package static let postsADayBeforeNoCopies = 100
    /// The shortest wait before the first check of a send, whatever RTOE NCBI gave.
    package static let firstCheckFloor: TimeInterval = 10
    /// A `Status=UNKNOWN` inside this many seconds of a send's Put is no news.
    package static let unknownGrace: TimeInterval = 300
    /// Reads in a row past the grace that end a send.
    package static let unknownReadsThatEndASend = 2
    /// The waits after each busy answer to a Put. One more busy answer after the last means not sent.
    package static let busyPutWaits: [TimeInterval] = [60, 120, 300]
    /// The wait before the one re-POST after a Put whose reply was lost.
    package static let lostPutWait: TimeInterval = 60
    /// The limit on one Put, past which nobody knows whether it arrived.
    package static let putTimeout: TimeInterval = 180
    /// Fetches of a reply that cannot be read, 60 s apart, before a person is asked.
    package static let fetchTries = 5
    package static let fetchWait: TimeInterval = 60
    /// The most of NCBI's words a file keeps, in bytes.
    package static let wordsLimit = 2048
    /// Failed checks in a row from which the words say so.
    package static let failedChecksThatAreSaid = 3
    /// The fewest seconds between any two contacts with BLAST from this Mac.
    package static let contactSpacing: TimeInterval = 11
    /// A last slot further ahead than this reads as now, since only a clock moved back leaves one.
    package static let gateFutureLimit: TimeInterval = 600
    /// How long a contact tries for the gate's lock before it goes on with its process's own spacing.
    package static let gateLockWait: TimeInterval = 5

    /// The wait after a check at this search age. 1 a minute to 10 min, every 5 min to 1 h, every 15 min to 6 h,
    /// and every 30 min after that, with no end while NCBI says WAITING. NCBI: "Do not poll for any single RID more
    /// often than once a minute."
    package static func checkInterval(atAge age: TimeInterval) -> TimeInterval {
        switch age {
        case ..<600: 60
        case ..<3600: 300
        case ..<21600: 900
        default: 1800
        }
    }
}
