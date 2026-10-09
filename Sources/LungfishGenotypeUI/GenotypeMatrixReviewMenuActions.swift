import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
/// The review commands the genotype matrix answers from the menu bar.
///
/// Selection > Genotype Call sends these to the first responder
/// with a nil target, so they reach the matrix only while it has the keyboard
/// focus. The protocol is public so the menu bar can name the selectors
/// without the matrix view itself being public.
@objc public protocol GenotypeMatrixReviewMenuActions: AnyObject {
    func markSelectionFalsePositive(_ sender: Any?)
    func markSelectionFalseNegative(_ sender: Any?)
    func clearSelectionReview(_ sender: Any?)
    func editSelectionComment(_ sender: Any?)
    func removeSelectionComments(_ sender: Any?)
}
