import Foundation

extension URLSessionTask: Cancellable {}

/// A transport-level, HTTP-specific error.
public struct GraphQLHTTPResponseError: Error, LocalizedError {
    public enum ErrorKind {
        case errorResponse
        case invalidResponse
        
        var description: String {
            switch self {
            case .errorResponse:
                return "Received error response"
            case .invalidResponse:
                return "Received invalid response"
            }
        }
    }
    
    /// The body of the response.
    public let body: Data?
    /// Information about the response as provided by the server.
    public let response: HTTPURLResponse
    public let kind: ErrorKind
    
    public var bodyDescription: String {
        if let body = body {
            if let description = String(data: body, encoding: response.textEncoding ?? .utf8) {
                return description
            } else {
                return "Unreadable response body"
            }
        } else {
            return "Empty response body"
        }
    }
    
    public var errorDescription: String? {
        return "\(kind.description) (\(response.statusCode) \(response.statusCodeDescription)): \(bodyDescription)"
    }
}

/// A network transport that uses HTTP POST requests to send GraphQL operations to a server, and that uses `URLSession` as the networking implementation.
public class HTTPNetworkTransport: NetworkTransport {
    let url: URL
    let session: URLSession
    let serializationFormat = JSONSerializationFormat.self
    
    /// Creates a network transport with the specified server URL and session configuration.
    ///
    /// - Parameters:
    ///   - url: The URL of a GraphQL server to connect to.
    ///   - configuration: A session configuration used to configure the session. Defaults to `URLSessionConfiguration.default`.
    ///   - sendOperationIdentifiers: Whether to send operation identifiers rather than full operation text, for use with servers that support query persistence. Defaults to false.
    public init(url: URL, configuration: URLSessionConfiguration = URLSessionConfiguration.default, sendOperationIdentifiers: Bool = false) {
        self.url = url
        self.session = URLSession(configuration: configuration)
        self.sendOperationIdentifiers = sendOperationIdentifiers
    }
    
    /// Send a GraphQL operation to a server and return a response.
    ///
    /// - Parameters:
    ///   - operation: The operation to send.
    ///   - completionHandler: A closure to call when a request completes.
    ///   - response: The response received from the server, or `nil` if an error occurred.
    ///   - error: An error that indicates why a request failed, or `nil` if the request was succesful.
    /// - Returns: An object that can be used to cancel an in progress request.
    public func send<Operation>(operation: Operation, completionHandler: @escaping (_ response: GraphQLResponse<Operation>?, _ error: Error?) -> Void) -> Cancellable {
        
        let request = sendOperationIdentifiers ? buildPersistedRequest(for: operation) : buildPostRequest(for: operation)
        let task = session.dataTask(with: request) { (data: Data?, response: URLResponse?, error: Error?) in
            if error != nil {
                completionHandler(nil, error)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                fatalError("Response should be an HTTPURLResponse")
            }
            
            if (!httpResponse.isSuccessful) {
                completionHandler(nil, GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .errorResponse))
                return
            }
            
            guard let data = data else {
                completionHandler(nil, GraphQLHTTPResponseError(body: nil, response: httpResponse, kind: .invalidResponse))
                return
            }
            
            do {
                guard let body =  try self.serializationFormat.deserialize(data: data) as? JSONObject else {
                    throw GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .invalidResponse)
                }
                let response = GraphQLResponse(operation: operation, body: body)
                completionHandler(response, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
        
        task.resume()
        
        return task
    }
    
    private let sendOperationIdentifiers: Bool
    
    private func buildPostRequest<Operation: GraphQLOperation>(for operation: Operation) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = requestBody(for: operation)
        request.httpBody = try! serializationFormat.serialize(value: body)
        
        return request
    }
    
    private func requestBody<Operation: GraphQLOperation>(for operation: Operation) -> GraphQLMap {
        return ["query": type(of: operation).requestString, "variables": operation.variables]
    }
    
    struct Extensions: Codable {
        struct PersistedQuery: Codable {
            let version: Int = 1
            let sha256Hash: String
        }
        let persistedQuery: PersistedQuery
        init(operationIdentifier: String) {
            persistedQuery = PersistedQuery(sha256Hash: operationIdentifier)
        }
    }
    
    private func buildPersistedRequest<Operation: GraphQLOperation>(for operation: Operation) -> URLRequest {
        
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            fatalError("Url shoud be valid")
        }
        guard let operationIdentifier = type(of: operation).operationIdentifier else {
            preconditionFailure("To send operation identifiers, Apollo types must be generated with operationIdentifiers")
        }
        guard let extensions = try? JSONEncoder().encode(Extensions(operationIdentifier: operationIdentifier)) else {
            fatalError("Unable to generate extensions")
        }
        
        
        var queryItems: [URLQueryItem] = []
        
        if let variables = operation.variables {
            queryItems.append(URLQueryItem(name: "variables", value: json(from: variables)))
        }
        queryItems.append(URLQueryItem(name: "extensions", value: String(data: extensions, encoding: .utf8)))
        
        urlComponents.queryItems = queryItems
        
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        return request
    }
    
    private func json(from object:Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return nil
        }
        return String(data: data, encoding: String.Encoding.utf8)
    }
}
