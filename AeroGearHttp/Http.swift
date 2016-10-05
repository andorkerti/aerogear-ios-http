/*
* JBoss, Home of Professional Open Source.
* Copyright Red Hat, Inc., and individual contributors
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation

/**
 The HTTP method verb:
 
 - GET:    GET http verb
 - HEAD:   HEAD http verb
 - DELETE:  DELETE http verb
 - POST:   POST http verb
 - PUT:    PUT http verb
 */
public enum HttpMethod: String {
    case GET = "GET"
    case HEAD = "HEAD"
    case DELETE = "DELETE"
    case POST = "POST"
    case PUT = "PUT"
}

/**
 The file request type:
 
 - Download: Download request
 - Upload:   Upload request
 */
enum FileRequestType {
    case download(String?)
    case upload(UploadType)
}

/**
 The Upload enum type:
 
 - Data:   for a generic NSData object
 - File:   for File passing the URL of the local file to upload
 - Stream:  for a Stream request passing the actual NSInputStream
 */
enum UploadType {
    case data(Foundation.Data)
    case file(URL)
    case stream(InputStream)
}

/**
Error domain.
**/
public let HttpErrorDomain = "HttpDomain"
/**
Request error.
**/
public let NetworkingOperationFailingURLRequestErrorKey = "NetworkingOperationFailingURLRequestErrorKey"
/**
Response error.
**/
public let NetworkingOperationFailingURLResponseErrorKey = "NetworkingOperationFailingURLResponseErrorKey"

public typealias ProgressBlock = (Int64, Int64, Int64) -> Void
public typealias CompletionBlock = (AnyObject?, NSError?) -> Void

/**
 Main class for performing HTTP operations across RESTful resources.
 */
open class Http {
    
    var baseURL: String?
    var session: URLSession
    var requestSerializer: RequestSerializer
    var responseSerializer: ResponseSerializer
    open var authzModule:  AuthzModule?
    
    fileprivate var delegate: SessionDelegate
    
    /**
     Initialize an HTTP object.
     
     :param: baseURL the remote base URL of the application (optional).
     :param: sessionConfig the SessionConfiguration object (by default it uses a defaultSessionConfiguration).
     :param: requestSerializer the actual request serializer to use when performing requests.
     :param: responseSerializer the actual response serializer to use upon receiving a response.
     
     :returns: the newly intitialized HTTP object
     */
    public init(baseURL: String? = nil,
        sessionConfig: URLSessionConfiguration = URLSessionConfiguration.default,
        requestSerializer: RequestSerializer = JsonRequestSerializer(),
        responseSerializer: ResponseSerializer = JsonResponseSerializer()) {
            self.baseURL = baseURL
            self.delegate = SessionDelegate()
            self.session = URLSession(configuration: sessionConfig, delegate: self.delegate, delegateQueue: OperationQueue.main)
            self.requestSerializer = requestSerializer
            self.responseSerializer = responseSerializer
    }
    
    deinit {
        self.session.finishTasksAndInvalidate()
    }
    
    /**
     Gateway to perform different http requests including multipart.
     
     :param: url the url of the resource.
     :param: parameters the request parameters.
     :param: method the method to be used.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    fileprivate func request(_ url: String, parameters: [String: AnyObject]? = nil,  method: HttpMethod,  credential: URLCredential? = nil, retry: Bool, completionHandler: @escaping CompletionBlock) {
        let block: () -> Void =  {
            let finalURL = self.calculateURL(self.baseURL, url: url)
            
            var request: URLRequest
            var task: URLSessionTask?
            var delegate: TaskDataDelegate
            // care for multipart request is multipart data are set
            if (self.hasMultiPartData(parameters)) {
                request = self.requestSerializer.multipartRequest(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
                task = self.session.uploadTask(withStreamedRequest: request)
                delegate = TaskUploadDelegate()
            } else {
                request = self.requestSerializer.request(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
                task = self.session.dataTask(with: request);
                delegate = TaskDataDelegate()
            }
            
            let innerCompletitionHandler: CompletionBlock = { (response, error) in
                if let authModule = self.authzModule {
                    if (error != nil && (error?.code == 400 || error?.code == 401 || error?.code == 403)  && retry) {
                        authModule.revokeLocalAccessToken()
                        self.request(url, parameters: parameters, method: method, credential: credential, retry: false, completionHandler: completionHandler)
                        return
                    }
                }
                
                completionHandler(response, error)
            }
            
            delegate.completionHandler = innerCompletitionHandler
            delegate.responseSerializer = self.responseSerializer
            delegate.credential = credential
            
            self.delegate[task] = delegate
            if let task = task {task.resume()}
        }
        
        // cater for authz and pre-authorize prior to performing request
        if (self.authzModule != nil) {
            self.authzModule?.requestAccess({ (response, error ) in
                // if there was an error during authz, no need to continue
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }
                
                // ..otherwise proceed normally
                block();
            })
        } else {
            block()
        }
    }
    
    /**
     Gateway to perform different file requests either download or upload.
     
     :param: url the url of the resource.
     :param: parameters the request parameters.
     :param: method the method to be used.
     :param: type the file request type
     :param: progress  a block that will be invoked to report progress during either download or upload.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    fileprivate func fileRequest(_ url: String, parameters: [String: AnyObject]? = nil,  method: HttpMethod, credential: URLCredential? = nil, type: FileRequestType, progress: ProgressBlock?, completionHandler: @escaping CompletionBlock) {
        
        let block: () -> Void  = {
            let finalURL = self.calculateURL(self.baseURL, url: url)
            var request: URLRequest
            // care for multipart request is multipart data are set
            if (self.hasMultiPartData(parameters)) {
                request = self.requestSerializer.multipartRequest(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
            } else {
                request = self.requestSerializer.request(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
            }
            
            var task: URLSessionTask?
            
            switch type {
            case .download(let destinationDirectory):
                task = self.session.downloadTask(with: request)
                
                let delegate = TaskDownloadDelegate()
                delegate.downloadProgress = progress
                delegate.destinationDirectory = destinationDirectory as NSString?;
                delegate.completionHandler = completionHandler
                delegate.credential = credential
                
                self.delegate[task] = delegate
                
            case .upload(let uploadType):
                switch uploadType {
                case .data(let data):
                    task = self.session.uploadTask(with: request, from: data)
                case .file(let url):
                    task = self.session.uploadTask(with: request, fromFile: url)
                case .stream(_):
                    task = self.session.uploadTask(withStreamedRequest: request)
                }
                
                let delegate = TaskUploadDelegate()
                delegate.uploadProgress = progress
                delegate.completionHandler = completionHandler
                delegate.credential = credential
                
                self.delegate[task] = delegate
            }
            
            if let task = task {task.resume()}
        }
        
        // cater for authz and pre-authorize prior to performing request
        if (self.authzModule != nil) {
            self.authzModule?.requestAccess({ (response, error ) in
                // if there was an error during authz, no need to continue
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }
                // ..otherwise proceed normally
                block();
            })
        } else {
            block()
        }
    }
    
    /**
     performs an HTTP GET request.
     
     :param: url         the url of the resource.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func GET(_ url: String, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, completionHandler: @escaping CompletionBlock) {
        request(url, parameters: parameters,  method:.GET,  credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP POST request.
     
     :param: url          the url of the resource.
     :param: parameters   the request parameters.
     :param: credential   the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func POST(_ url: String, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, completionHandler: @escaping CompletionBlock) {
        request(url, parameters: parameters, method:.POST, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP PUT request.
     
     :param: url          the url of the resource.
     :param: parameters   the request parameters.
     :param: credential   the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func PUT(_ url: String, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, completionHandler: @escaping CompletionBlock) {
        request(url, parameters: parameters, method:.PUT, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP DELETE request.
     
     :param: url         the url of the resource.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func DELETE(_ url: String, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, completionHandler: @escaping CompletionBlock) {
        request(url, parameters: parameters, method:.DELETE, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     performs an HTTP HEAD request.
     
     :param: url         the url of the resource.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func HEAD(_ url: String, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, completionHandler: @escaping CompletionBlock) {
        request(url, parameters: parameters, method:.HEAD, credential: credential, retry: true, completionHandler: completionHandler)
    }
    
    /**
     Request to download a file.
     
     :param: url                     the URL of the downloadable resource.
     :param: destinationDirectory    the destination directory where the file would be stored, if not specified. application's default '.Documents' directory would be used.
     :param: parameters              the request parameters.
     :param: credential              the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: method                  the method to be used, by default a .GET request.
     :param: progress                a block that will be invoked to report progress during download.
     :param: completionHandler       a block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func download(_ url: String,  destinationDirectory: String? = nil, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, method: HttpMethod = .GET, progress: ProgressBlock?, completionHandler: @escaping CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .download(destinationDirectory), progress: progress, completionHandler: completionHandler)
    }
    
    /**
     Request to upload a file using an NURL of a local file.
     
     :param: url         the URL to upload resource into.
     :param: file        the URL of the local file to be uploaded.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: method      the method to be used, by default a .POST request.
     :param: progress    a block that will be invoked to report progress during upload.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func upload(_ url: String,  file: URL, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: @escaping CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .upload(.file(file)), progress: progress, completionHandler: completionHandler)
    }
    
    /**
     Request to upload a file using a raw NSData object.
     
     :param: url         the URL to upload resource into.
     :param: data        the data to be uploaded.
     :param: parameters  the request parameters.
     :param: credential  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     :param: method       the method to be used, by default a .POST request.
     :param: progress     a block that will be invoked to report progress during upload.
     :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func upload(_ url: String,  data: Data, parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: @escaping CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .upload(.data(data)), progress: progress, completionHandler: completionHandler)
    }
    
    /**
     Request to upload a file using an NSInputStream object.
     
     - parameter url:         the URL to upload resource into.
     - parameter stream:      the stream that will be used for uploading.
     - parameter parameters:  the request parameters.
     - parameter credential:  the credentials to use for basic/digest auth (Note: it is advised that HTTPS should be used by default).
     - parameter method:      the method to be used, by default a .POST request.
     - parameter progress:    a block that will be invoked to report progress during upload.
     - parameter completionHandler: A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
     */
    open func upload(_ url: String,  stream: InputStream,  parameters: [String: AnyObject]? = nil, credential: URLCredential? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: @escaping CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, credential: credential, type: .upload(.stream(stream)), progress: progress, completionHandler: completionHandler)
    }
    
    
    // MARK: Private API
    
    // MARK: SessionDelegate
    class SessionDelegate: NSObject, URLSessionDelegate,  URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate {
        
        fileprivate var delegates: [Int:  TaskDelegate]
        
        fileprivate subscript(task: URLSessionTask?) -> TaskDelegate? {
            get {
                guard let task = task else {
                    return nil
                }
                return self.delegates[task.taskIdentifier]
            }
            
            set (newValue) {
                guard let task = task else {
                    return
                }
                self.delegates[task.taskIdentifier] = newValue
            }
        }
        
        required override init() {
            self.delegates = Dictionary()
            super.init()
        }
        
        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            // TODO
        }
        
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(Foundation.URLSession.AuthChallengeDisposition.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        }
        
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            // TODO
        }
        
        // MARK: NSURLSessionTaskDelegate
        
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
            } else {
                self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, needNewBodyStream: completionHandler)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if let delegate = self[task] as? TaskUploadDelegate {
                delegate.URLSession(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let delegate = self[task] {
                delegate.urlSession(session, task: task, didCompleteWithError: error)
                
                self[task] = nil
            }
        }
        
        // MARK: NSURLSessionDataDelegate
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome downloadTask: URLSessionDownloadTask) {
            let downloadDelegate = TaskDownloadDelegate()
            self[downloadTask] = downloadDelegate
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if let delegate = self[dataTask] as? TaskDataDelegate {
                delegate.urlSession(session, dataTask: dataTask, didReceive: data)
            }
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) {
            completionHandler(proposedResponse)
        }
        
        // MARK: NSURLSessionDownloadDelegate
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let delegate = self[downloadTask] as? TaskDownloadDelegate {
                delegate.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if let delegate = self[downloadTask] as? TaskDownloadDelegate {
                delegate.urlSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
            if let delegate = self[downloadTask] as? TaskDownloadDelegate {
                delegate.urlSession(session, downloadTask: downloadTask, didResumeAtOffset: fileOffset, expectedTotalBytes: expectedTotalBytes)
            }
        }
    }
    
    // MARK: NSURLSessionTaskDelegate
    class TaskDelegate: NSObject, URLSessionTaskDelegate {
        
        var data: Data? { return nil }
        var completionHandler:  ((AnyObject?, NSError?) -> Void)?
        var responseSerializer: ResponseSerializer?
        
        var credential: URLCredential?
        
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            
            completionHandler(request)
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            var disposition: Foundation.URLSession.AuthChallengeDisposition = .performDefaultHandling
            var credential: URLCredential?
            
            if challenge.previousFailureCount > 0 {
                disposition = .cancelAuthenticationChallenge
            } else {
                credential = self.credential ?? session.configuration.urlCredentialStorage?.defaultCredential(for: challenge.protectionSpace)
                
                if credential != nil {
                    disposition = .useCredential
                }
            }
            
            completionHandler(disposition, credential)
        }
        
        
        func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: (@escaping (InputStream?) -> Void)) {
            
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil {
                completionHandler?(nil, error as NSError?)
                return
            }
            
            
            let response = task.response as! HTTPURLResponse
            
            if  let _ = task as? URLSessionDownloadTask {
                completionHandler?(response, error as NSError?)
                return
            }
            
            var responseObject: AnyObject? = nil
            do {
                if let data = data {
                    try self.responseSerializer?.validateResponse(response, data: data)
                    responseObject = self.responseSerializer?.response(data) as AnyObject?
                    completionHandler?(responseObject, nil)
                }
            } catch let error as NSError {
                completionHandler?(responseObject, error)
            }
        }
    }
    
    // MARK: NSURLSessionDataDelegate
    class TaskDataDelegate: TaskDelegate, URLSessionDataDelegate {
        
        fileprivate var mutableData: NSMutableData
        
        override var data: Data? {
            return self.mutableData as Data
        }
        
        override init() {
            self.mutableData = NSMutableData()
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            completionHandler(.allow)
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.mutableData.append(data)
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) {
            let cachedResponse = proposedResponse
            completionHandler(cachedResponse)
        }
    }
    
    // MARK: NSURLSessionDownloadDelegate
    class TaskDownloadDelegate: TaskDelegate, URLSessionDownloadDelegate {
        
        var downloadProgress: ((Int64, Int64, Int64) -> Void)?
        var resumeData: Data?
        var destinationDirectory: NSString?
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let filename = downloadTask.response?.suggestedFilename
            
            // calculate final destination
            var finalDestination: URL
            if (destinationDirectory == nil) {  // use 'default documents' directory if not set
                // use default documents directory
                let documentsDirectory  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] as URL
                finalDestination = documentsDirectory.appendingPathComponent(filename!)
            } else {
                // check that the directory exists
                let path = destinationDirectory?.appendingPathComponent(filename!)
                finalDestination = URL(fileURLWithPath: path!)
            }
            
            do {
                try FileManager.default.moveItem(at: location, to: finalDestination)
            } catch _ {
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            
            self.downloadProgress?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        }
    }
    
    // MARK: NSURLSessionTaskDelegate
    class TaskUploadDelegate: TaskDataDelegate {
        
        var uploadProgress: ((Int64, Int64, Int64) -> Void)?
        
        func URLSession(_ session: Foundation.URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            self.uploadProgress?(bytesSent, totalBytesSent, totalBytesExpectedToSend)
        }
    }
    
    // MARK: Utility methods
    open func calculateURL(_ baseURL: String?,  url: String) -> URL {
        var url = url
        if (baseURL == nil || url.hasPrefix("http")) {
            return URL(string: url)!
        }
        
        let finalURL = URL(string: baseURL!)!
        if (url.hasPrefix("/")) {
            url = url.substring(from: url.characters.index(url.startIndex, offsetBy: 0))
        }
        
        return finalURL.appendingPathComponent(url);
    }
    
    open func hasMultiPartData(_ parameters: [String: AnyObject]?) -> Bool {
        if (parameters == nil) {
            return false
        }
        
        var isMultiPart = false
        for (_, value) in parameters! {
            if value is MultiPartData {
                isMultiPart = true
                break
            }
        }
        
        return isMultiPart
    }
}
