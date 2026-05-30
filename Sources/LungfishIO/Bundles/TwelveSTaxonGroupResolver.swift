import Foundation

public enum TwelveSTaxonGroupResolver {
    public static let defaultDisplayGroups = ["Mammal", "Fish", "Bird", "Reptile", "Amphibian"]

    public static func groups(for row: TwelveSScientificNameCountRow) -> [String] {
        let explicitGroups = normalizedGroups(row.taxonGroups)
        if !explicitGroups.isEmpty {
            return explicitGroups
        }

        var names = [row.scientificName]
        names.append(contentsOf: row.commonNames)
        names.append(contentsOf: row.potentialMatches)
        for match in row.alternateMatches {
            names.append(match.displayName)
            if let scientificName = match.scientificName { names.append(scientificName) }
            if let commonName = match.commonName { names.append(commonName) }
            if let taxonomy = match.taxonomy { names.append(taxonomy) }
        }
        return inferredGroups(from: names)
    }

    public static func groups(
        scientificName: String,
        commonName: String? = nil,
        displayName: String? = nil,
        taxonomy: String? = nil,
        explicitGroup: String? = nil
    ) -> [String] {
        let explicitGroups = normalizedGroups([explicitGroup ?? ""])
        if !explicitGroups.isEmpty {
            return explicitGroups
        }
        return inferredGroups(from: [
            scientificName,
            commonName ?? "",
            displayName ?? "",
            taxonomy ?? "",
        ])
    }

    private static func normalizedGroups(_ groups: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in groups {
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let canonical = canonicalGroupName(for: trimmed)
            guard seen.insert(canonical.lowercased()).inserted else { continue }
            result.append(canonical)
        }
        return result
    }

    private static func canonicalGroupName(for group: String) -> String {
        switch group.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mammal", "mammalia":
            return "Mammal"
        case "fish", "actinopteri", "actinopterygii", "chondrichthyes":
            return "Fish"
        case "bird", "aves":
            return "Bird"
        case "reptile", "reptilia":
            return "Reptile"
        case "amphibian", "amphibia":
            return "Amphibian"
        default:
            return group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func inferredGroups(from names: [String]) -> [String] {
        let normalizedNames = names.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard !normalizedNames.isEmpty else { return [] }

        let genera = Set(normalizedNames.compactMap(Self.genus))
        let tokens = Set(normalizedNames.flatMap(Self.tokens))
        var groups = Set<String>()

        if !genera.isDisjoint(with: mammalGenera) || !tokens.isDisjoint(with: mammalTokens) {
            groups.insert("Mammal")
        }
        if !genera.isDisjoint(with: fishGenera) || !tokens.isDisjoint(with: fishTokens) {
            groups.insert("Fish")
        }
        if !genera.isDisjoint(with: birdGenera) || !tokens.isDisjoint(with: birdTokens) {
            groups.insert("Bird")
        }
        if !genera.isDisjoint(with: reptileGenera) || !tokens.isDisjoint(with: reptileTokens) {
            groups.insert("Reptile")
        }
        if !genera.isDisjoint(with: amphibianGenera) || !tokens.isDisjoint(with: amphibianTokens) {
            groups.insert("Amphibian")
        }

        return defaultDisplayGroups.filter { groups.contains($0) }
    }

    private static func genus(from text: String) -> String? {
        text.split { !$0.isLetter && !$0.isNumber }.first.map { String($0).lowercased() }
    }

    private static func tokens(from text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() }
    }

    private static let mammalGenera: Set<String> = [
        "balaenoptera", "bos", "canis", "capra", "cervus", "delphinus", "equus", "felis",
        "gorilla", "homo", "mus", "odocoileus", "ovis", "pan", "panthera", "phocoena",
        "pongo", "puma", "rattus", "sus", "tragelaphus", "tursiops",
    ]

    private static let fishGenera: Set<String> = [
        "acanthurus", "albula", "caranx", "calotomus", "chlorurus", "coryphaena",
        "euthynnus", "gobio", "katsuwonus", "kuhlia", "monotaxis", "mugil",
        "myripristis", "naso", "salmo", "scarus", "scomber", "thunnus",
    ]

    private static let birdGenera: Set<String> = [
        "anas", "cygnus", "gallus", "meleagris", "passer", "phasianus", "taeniopygia",
    ]

    private static let reptileGenera: Set<String> = [
        "alligator", "anolis", "boa", "chelonoidis", "chelonia", "crocodylus", "lacerta",
        "python", "testudo", "varanus",
    ]

    private static let amphibianGenera: Set<String> = [
        "ambystoma", "bufo", "lithobates", "rana", "xenopus",
    ]

    private static let mammalTokens: Set<String> = [
        "ape", "bat", "bongo", "cat", "cattle", "chimpanzee", "cow", "deer", "dog",
        "goat", "horse", "human", "mammal", "monkey", "pig", "primate", "rat", "seal",
        "sheep", "wolf",
    ]

    private static let fishTokens: Set<String> = [
        "barracuda", "bass", "bonefish", "bream", "cod", "dolphinfish", "eel", "fish",
        "flagtail", "goby", "gudgeon", "mullet", "parrotfish", "salmon", "shark",
        "surgeonfish", "tuna", "tunny",
    ]

    private static let birdTokens: Set<String> = [
        "bird", "chicken", "duck", "mallard", "swan", "turkey",
    ]

    private static let reptileTokens: Set<String> = [
        "alligator", "crocodile", "lizard", "reptile", "snake", "tortoise", "turtle",
    ]

    private static let amphibianTokens: Set<String> = [
        "amphibian", "frog", "newt", "salamander", "toad",
    ]
}

public extension TwelveSScientificNameCountRow {
    var displayTaxonGroups: [String] {
        TwelveSTaxonGroupResolver.groups(for: self)
    }
}
