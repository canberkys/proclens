import Foundation
import ProcLensHelperProtocol

// ProcLensHelper: privileged XPC helper, started on demand by launchd (SMAppService.daemon) as root.
// It only serves the app that satisfies the code-signing requirement in `HelperListenerDelegate`.

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
