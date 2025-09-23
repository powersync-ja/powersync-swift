
/// A temporary update broker which collects table updates during a write operation.
class UpdateBroker {
    var updates: Set<String> = []
}
