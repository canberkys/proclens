import Observation
import ProcLensCore

@Observable @MainActor
final class PerformanceViewModel {
    var latest: SystemSnapshot?
}
