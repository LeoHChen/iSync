import Foundation

public enum PhotoScanner {
    /// Lists every file in /DCIM over four connections. This took about 4 s for 35,000 files.
    public static func scan(udid: String, onProgress: ((Int, Int) -> Void)? = nil) throws -> [RemoteFile] {
        let root = try AFCClient.connect(udid: udid)
        var names: [String] = []
        for entry in try root.list("/DCIM") where !entry.hasPrefix(".") {
            let path = "/DCIM/\(entry)"
            guard let info = root.info(path) else { continue }
            if info["st_ifmt"] == "S_IFDIR" {
                for f in (try? root.list(path)) ?? [] where !f.hasPrefix(".") { names.append("\(path)/\(f)") }
            } else {
                names.append(path)
            }
        }

        let next = Locked(0)
        let found = Locked<[RemoteFile]>([])
        let failure = Locked<Error?>(nil)
        let total = names.count
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                let afc = try AFCClient.connect(udid: udid)
                while true {
                    let i: Int = next.with { n in defer { n += 1 }; return n }
                    if i >= total { break }
                    guard let s = afc.info(names[i]), s["st_ifmt"] == "S_IFREG" else { continue }
                    let file = RemoteFile(
                        path: names[i],
                        size: Int64(s["st_size"] ?? "") ?? 0,
                        modifiedNs: Int64(s["st_mtime"] ?? "") ?? 0)
                    let done: Int = found.with { list in list.append(file); return list.count }
                    if done % 1000 == 0 { onProgress?(done, total) }
                }
            } catch {
                failure.with { $0 = error }
            }
        }
        if let error = failure.with({ $0 }) { throw error }
        return found.with { $0 }
    }
}
