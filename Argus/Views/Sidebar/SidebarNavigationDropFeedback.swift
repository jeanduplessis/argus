import SwiftUI

/// SwiftUI can deliver a final dropUpdated after dropExited or performDrop.
/// Region identity is separate from the destination: several headers can append
/// to the same Collection. Only entry may acquire feedback; late updates must
/// not restore a guide after that region has been cleared.
@MainActor
final class SidebarNavigationDropFeedback: ObservableObject {
    struct Destination: Equatable {
        let ownerId: UUID
        let placement: SidebarNavigationDropPlacement
    }

    @Published private(set) var destination: Destination?
    private var enteredOwnerId: UUID?
    private(set) var projectBlockDrag: SidebarProjectBlockDrag?

    func beginProjectBlockDrag(_ drag: SidebarNavigationDrag) {
        end()
        if case .projectBlock(let source) = drag { projectBlockDrag = source }
    }

    func placement(for ownerId: UUID) -> SidebarNavigationDropPlacement? {
        destination?.ownerId == ownerId ? destination?.placement : nil
    }

    func enter(_ ownerId: UUID, placement: SidebarNavigationDropPlacement?) {
        enteredOwnerId = ownerId
        destination = placement.map { Destination(ownerId: ownerId, placement: $0) }
    }

    func update(_ ownerId: UUID, placement: SidebarNavigationDropPlacement?) {
        guard enteredOwnerId == ownerId else { return }
        enter(ownerId, placement: placement)
    }

    func exit(_ ownerId: UUID) {
        guard enteredOwnerId == ownerId else { return }
        enteredOwnerId = nil
        destination = nil
    }

    func end() {
        enteredOwnerId = nil
        destination = nil
        projectBlockDrag = nil
    }
}
