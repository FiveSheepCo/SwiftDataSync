import Foundation

struct SDSStateError: Error {
    let state: SDSSynchronizationViewModel.State
    
    init(state: SDSSynchronizationViewModel.State) {
        self.state = state
    }
}
