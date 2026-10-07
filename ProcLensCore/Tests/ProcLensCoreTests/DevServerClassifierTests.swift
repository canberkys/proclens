import Testing
@testable import ProcLensCore

struct DevServerClassifierTests {
    private let c = DevServerClassifier.shared

    private func port(_ p: UInt16, proto: ListeningPort.TransportProtocol = .tcp) -> ListeningPort {
        ListeningPort(port: p, proto: proto, address: "127.0.0.1", isLoopbackOnly: true, pid: 1,
                      processID: ProcessID(pid: 1, startTime: 1))
    }

    @Test func rulesLoadFromBundle() {
        let m = c.classify(port: 1, processName: "x", commandLine: "")
        #expect(m.framework == "Unknown listener")  // default also proves the file decoded
        #expect(c.classify(port: 9, processName: "postgres", commandLine: "").framework == "PostgreSQL")
    }

    @Test func viteAndNextBeatNode() {
        let vite = c.classify(port: port(5173), processName: "node", commandLine: "node /app/node_modules/.bin/vite --host")
        #expect(vite.framework == "Vite" && vite.category == .web && vite.confidence >= 90)
        let next = c.classify(port: port(3000), processName: "next-server", commandLine: "next-server (v15)")
        #expect(next.framework == "Next.js")
    }

    @Test func pythonServers() {
        #expect(c.classify(port: 8000, processName: "Python", commandLine: "python manage.py runserver").framework == "Django")
        #expect(c.classify(port: 8000, processName: "python3", commandLine: "python3 -m uvicorn app:app").framework == "Uvicorn")
        #expect(c.classify(port: 8000, processName: "python3", commandLine: "gunicorn -w 4 app:app").framework == "Gunicorn")
        #expect(c.classify(port: 5000, processName: "python3", commandLine: "python3 -m flask run").framework == "Flask")
        #expect(c.classify(port: 9999, processName: "python3", commandLine: "python3 script.py").framework == "Python")
    }

    @Test func otherRules() {
        #expect(c.classify(port: 1313, processName: "hugo", commandLine: "hugo server").framework == "Hugo")
        #expect(c.classify(port: 4000, processName: "ruby", commandLine: "jekyll serve").framework == "Jekyll")
        #expect(c.classify(port: 3000, processName: "ruby", commandLine: "ruby bin/rails server").framework == "Rails")
        #expect(c.classify(port: 8000, processName: "php", commandLine: "php -S localhost:8000").framework == "PHP built-in server")
        #expect(c.classify(port: 4000, processName: "bun", commandLine: "bun run dev").framework == "Bun")
        #expect(c.classify(port: 4000, processName: "deno", commandLine: "deno task start").framework == "Deno")
        #expect(c.classify(port: 2375, processName: "com.docker.backend", commandLine: "").category == .container)
        #expect(c.classify(port: 2375, processName: "vpnkit-bridge", commandLine: "").category == .container)
    }

    @Test func wholeWordRulesDoNotMatchSubstrings() {
        // "bun" inside "bundle", "next" inside "context", "node" inside "nodemon-less" paths of other tools.
        let m = c.classify(port: 9999, processName: "tool", commandLine: "tool /Users/me/bundle/context/run")
        #expect(m.framework == "Unknown listener")
    }

    @Test func portFallbacks() {
        #expect(c.classify(port: 5432, processName: "x", commandLine: "").category == .database)
        #expect(c.classify(port: 3456, processName: "x", commandLine: "").category == .web)
        #expect(c.classify(port: 5555, processName: "x", commandLine: "").confidence == 58)
        #expect(c.classify(port: 8123, processName: "x", commandLine: "").category == .web)
        #expect(c.classify(port: 4200, processName: "x", commandLine: "").category == .web)
        let d = c.classify(port: 22, processName: "sshd", commandLine: "")
        #expect(d.framework == "Unknown listener" && d.category == .unknown && d.confidence == 20)
    }

    @Test func isLikelyHTTP() {
        let vite = c.classify(port: port(5173), processName: "node", commandLine: "vite")
        #expect(c.isLikelyHTTP(port: port(5173), match: vite))
        let pg = c.classify(port: port(5432), processName: "postgres", commandLine: "")
        #expect(!c.isLikelyHTTP(port: port(5432), match: pg))
        let node = c.classify(port: port(5173), processName: "node", commandLine: "server.js")
        #expect(c.isLikelyHTTP(port: port(5173), match: node))      // runtime on a common dev port
        let node2 = c.classify(port: port(7777), processName: "node", commandLine: "server.js")
        #expect(!c.isLikelyHTTP(port: port(7777), match: node2))
        #expect(!c.isLikelyHTTP(port: port(5173, proto: .udp), match: vite))
    }
}
