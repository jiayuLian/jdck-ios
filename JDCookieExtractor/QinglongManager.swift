import Foundation

struct QinglongError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

/// 青龙面板 OpenAPI 封装，逻辑与 Android 版 QinglongUtil 一致：
/// 取 token -> 查 JD_COOKIE -> 更新或新建 -> 启用。
final class QinglongManager {
    static let shared = QinglongManager()
    private init() {}

    private func buildURL(baseURL: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed) else { throw QinglongError(msg: "面板地址无效") }
        url.append(path: path)
        if !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = query
            url = comps.url!
        }
        return url
    }

    func getToken(baseURL: String, clientId: String, clientSecret: String) async throws -> String {
        let url = try buildURL(baseURL: baseURL, path: "/open/auth/token",
                               query: [URLQueryItem(name: "client_id", value: clientId),
                                       URLQueryItem(name: "client_secret", value: clientSecret)])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let code: Int; let message: String?; let data: Inner?; struct Inner: Decodable { let token: String } }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard r.code == 200, let token = r.data?.token else {
            throw QinglongError(msg: r.message ?? "获取 token 失败 (code \(r.code))")
        }
        return token
    }

    private func authRequest(url: URL, method: String, body: Data? = nil, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    func pushCookie(baseURL: String, clientId: String, clientSecret: String, cookie: String) async throws -> String {
        let token = try await getToken(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)

        // 1) 查找已有的 JD_COOKIE
        let listURL = try buildURL(baseURL: baseURL, path: "/open/envs",
                                   query: [URLQueryItem(name: "searchValue", value: "JD_COOKIE")])
        let listReq = authRequest(url: listURL, method: "GET", token: token)
        let (ldata, _) = try await URLSession.shared.data(for: listReq)
        struct ListR: Decodable { let code: Int; let data: [Env]?; struct Env: Decodable { let id: Int; let name: String; let value: String; let status: Int? } }
        let list = try JSONDecoder().decode(ListR.self, from: ldata)
        let existing = list.data?.first(where: { $0.name == "JD_COOKIE" })

        let encoder = JSONEncoder()
        var envId: Int

        if let env = existing {
            // 2a) 已存在 -> 更新
            struct EnvUpdate: Encodable { let id: Int; let name: String; let value: String; let remarks: String }
            let body = try encoder.encode(EnvUpdate(id: env.id, name: "JD_COOKIE", value: cookie, remarks: "iOS"))
            let updURL = try buildURL(baseURL: baseURL, path: "/open/envs")
            let updReq = authRequest(url: updURL, method: "PUT", body: body, token: token)
            let (udata, _) = try await URLSession.shared.data(for: updReq)
            struct CodeR: Decodable { let code: Int; let message: String? }
            let ur = try JSONDecoder().decode(CodeR.self, from: udata)
            guard ur.code == 200 else { throw QinglongError(msg: ur.message ?? "更新环境变量失败") }
            envId = env.id
        } else {
            // 2b) 不存在 -> 新建
            struct EnvCreate: Encodable { let name: String; let value: String; let remarks: String }
            let body = try encoder.encode(EnvCreate(name: "JD_COOKIE", value: cookie, remarks: "iOS"))
            let cURL = try buildURL(baseURL: baseURL, path: "/open/envs")
            let cReq = authRequest(url: cURL, method: "POST", body: body, token: token)
            let (cdata, _) = try await URLSession.shared.data(for: cReq)
            struct IdR: Decodable { let code: Int; let message: String?; let data: Inner?; struct Inner: Decodable { let id: Int } }
            let cr = try JSONDecoder().decode(IdR.self, from: cdata)
            guard cr.code == 200, let newId = cr.data?.id else { throw QinglongError(msg: cr.message ?? "创建环境变量失败") }
            envId = newId
        }

        // 3) 启用
        struct EnableBody: Encodable { let id: Int; let status: Int }
        let ebody = try encoder.encode([EnableBody(id: envId, status: 1)])
        let eURL = try buildURL(baseURL: baseURL, path: "/open/envs/enable")
        let eReq = authRequest(url: eURL, method: "PUT", body: ebody, token: token)
        let (edata, _) = try await URLSession.shared.data(for: eReq)
        struct CodeR: Decodable { let code: Int; let message: String? }
        let er = try JSONDecoder().decode(CodeR.self, from: edata)
        guard er.code == 200 else { throw QinglongError(msg: er.message ?? "启用环境变量失败") }

        return existing == nil ? "已新建并启用 JD_COOKIE（env id \(envId)）" : "已更新并启用 JD_COOKIE（env id \(envId)）"
    }
}
