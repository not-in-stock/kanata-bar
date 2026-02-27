enum AppState: Equatable {
    case stopped
    case starting
    case running(String)
    case restarting
}
