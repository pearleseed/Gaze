import Foundation
import GazeCore

package enum ReleaseURLPolicy {
	package static let feed = URL(string: "https://api.github.com/repos/\(AppIdentity.repositorySlug)/releases/latest")!
	package static let releases = AppIdentity.releasesURL
	package static let maximumFeedBytes = 512 * 1024
	package static let maximumChecksumBytes = 4 * 1024

	private static func validatedHTTPSComponents(_ url: URL) -> URLComponents? {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.scheme?.lowercased() == "https",
			components.user == nil,
			components.password == nil,
			components.port == nil || components.port == 443,
			components.fragment == nil
		else { return nil }
		let segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
		guard !segments.contains("."), !segments.contains("..") else { return nil }
		return components
	}

	package static func isTrustedFeed(_ url: URL) -> Bool {
		guard let components = validatedHTTPSComponents(url),
			components.host?.lowercased() == "api.github.com"
		else { return false }
		let base = "/repos/\(AppIdentity.repositorySlug)/releases"
		if components.path == "\(base)/latest" { return true }
		let assetsPrefix = "\(base)/assets/"
		return components.path.hasPrefix(assetsPrefix) && components.path.count > assetsPrefix.count
	}

	package static func isTrustedDownload(_ url: URL) -> Bool {
		guard let components = validatedHTTPSComponents(url),
			let host = components.host?.lowercased(),
			!components.path.isEmpty,
			components.path != "/"
		else { return false }
		if host == "github.com" {
			let prefix = "/\(AppIdentity.repositorySlug)/releases/download/"
			return components.path.hasPrefix(prefix) && components.path.count > prefix.count
		}
		return host == "release-assets.githubusercontent.com"
			|| host == "objects.githubusercontent.com"
	}

	/// Whether a download redirect hop is safe to follow.
	package static func isTrustedDownloadHop(_ url: URL) -> Bool {
		isTrustedDownload(url)
	}

	package static func isTrustedBrowserDestination(_ url: URL) -> Bool {
		url == releases || isTrustedDownload(url)
	}

	package static func download(_ value: String?) -> URL? {
		guard let value, value.utf8.count <= 4096, let url = URL(string: value), isTrustedDownload(url) else {
			return nil
		}
		return url
	}

	package static func sessionConfiguration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.httpShouldSetCookies = false
		configuration.httpCookieStorage = nil
		configuration.urlCredentialStorage = nil
		configuration.urlCache = nil
		configuration.timeoutIntervalForRequest = 15
		configuration.timeoutIntervalForResource = 20
		return configuration
	}
}

package final class ReleaseFeedRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
	package override init() { super.init() }

	package func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		guard let url = request.url, ReleaseURLPolicy.isTrustedFeed(url) else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}
}

package final class ReleaseDownloadRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
	package override init() { super.init() }

	package func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		guard let url = request.url, ReleaseURLPolicy.isTrustedDownloadHop(url) else {
			completionHandler(nil)
			return
		}
		completionHandler(request)
	}
}
