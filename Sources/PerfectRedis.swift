//
//  PerfectRedis.swift
//  Perfect-Redis
//
//  Created by Kyle Jessup on 2016-06-03.
//	Copyright (C) 2016 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectNet

public let redisDefaultPort = 6379
let redisNetTimeout = 5.0
let redisDefaultReadSize = 2048

let cr: UInt8 = 13
let lf: UInt8 = 10
let sp: UInt8 = 32

extension String {
    var bytes: [UInt8] { return Array(self.utf8) }
}

extension UInt8 {
    var hexString: String {
        var s = ""
        let b = self >> 4
        s.append(String(Character(UnicodeScalar(b > 9 ? b - 10 + 65 : b + 48))))
        let b2 = self & 0x0F
        s.append(String(Character(UnicodeScalar(b2 > 9 ? b2 - 10 + 65 : b2 + 48))))
        return s
    }
}

extension Array where Element: UnsignedInteger {
    var nullTerminatedPointer: UnsafePointer<CChar> {
        if self.last == 0 {
            return UnsafePointer(UnsafeMutableRawPointer(mutating: self).assumingMemoryBound(to: CChar.self))
        }
        var ary = self
        ary.append(0)
        return UnsafePointer(UnsafeMutableRawPointer(mutating: ary).assumingMemoryBound(to: CChar.self))
    }
    
    var string: String {
        return String(validatingUTF8: self.nullTerminatedPointer) ?? ""
    }
}

private func hexString(fromArray: [UInt8]) -> String {
    var s = ""
    for v in fromArray {
        s.append("\\x")
        let b = v >> 4
        s.append(String(Character(UnicodeScalar(b > 9 ? b - 10 + 65 : b + 48))))
        let b2 = v & 0x0F
        s.append(String(Character(UnicodeScalar(b2 > 9 ? b2 - 10 + 65 : b2 + 48))))
    }
    return s
}

public enum RedisResponse {
    case error(type: String, msg: String)
    case simpleString(String)
    case bulkString([UInt8]?)
    case integer(Int)
    case array([RedisResponse])
    
    /// Returns true if the response is the Redis standard +OK
    public var isSimpleOK: Bool {
        guard case .simpleString(let s) = self , s == "OK" else {
            return false
        }
        return true
    }
    
    public func toString() -> String? {
        switch self {
        case .error(let type, let msg):
            return "\(type) \(msg)"
        case .simpleString(let str):
            return str
        case .bulkString(let bytes):
            if let b = bytes {
                return b.string
            } else {
                return nil
            }
        case .integer(let int):
            return "\(int)"
        case.array(let array):
            var ary = "["
            ary.append(array.map { $0.toString() ?? "nil" }.joined(separator: ", "))
            ary.append("]")
            return ary
        }
    }
    
    // to a not null terminated char array
    func toBytes() -> [UInt8] {
        switch self {
        case .error(let type, let msg):
            return "-\(type) \(msg)\r\n".bytes
        case .simpleString(let str):
            return "+\(str)\r\n".bytes
        case .bulkString(let bytes):
            if let b = bytes {
                var ary = "$\(b.count)\r\n".bytes
                ary.append(contentsOf: b)
                ary.append(contentsOf: "\r\n".bytes)
                return ary
            } else {
                return "$-1\r\n".bytes
            }
        case .integer(let int):
            return ":\(int)\r\n".bytes
        case.array(let array):
            
            var ary = "*\(array.count)\r\n".bytes
            for elem in array {
                ary.append(contentsOf: elem.toBytes())
            }
            return ary
        }
    }
    
    static func readResponse(client: RedisClient, timeoutSeconds: Double, callback: @escaping (RedisResponse) -> ()) {
        if let line = client.pullLineFromBuffer() {
            let endIndex = line.endIndex
            let id = line[0]
            switch Character(UnicodeScalar(id)) {
            case "-": // error
                for i in line.startIndex..<endIndex {
                    if i == 32 {
                        let type = Array(line[line.startIndex..<i])
                        let msg = Array(line[1+i..<endIndex])
                        return callback(.error(type: type.string, msg: msg.string))
                    }
                }
            case "+": // string
                return callback(.simpleString(Array(line[1..<endIndex]).string))
            case "$": // bulk string
                if let i = Int(Array(line[1..<endIndex]).string) {
                    if i == -1 {
                        return callback(.bulkString(nil))
                    }
                    return client.extractBytesFromBuffer(size: i + 2) { // we are also reading the trailing crlf
                        bytes in
                        guard let b = bytes else {
                            return callback(.error(type: "NET", msg: "Invalid response from server"))
                        }
                        let subB = Array(b[b.startIndex..<b.endIndex-2])
                        return callback(.bulkString(subB))
                    }
                }
            case ":": // integer
                if let i = Int(Array(line[1..<endIndex]).string) {
                    return callback(.integer(i))
                }
            case "*": // array
                if let i = Int(Array(line[1..<endIndex]).string) {
                    return readElements(client: client, count: i, into: [RedisResponse](), arrayCallback: callback)
                }
            default:
                ()
            }
            return callback(.error(type: "NET", msg: "Invalid response from server"))
        } else {
            client.fillBuffer(timeoutSeconds: timeoutSeconds) {
                ok in
                
                guard ok else {
                    return callback(.error(type: "NET", msg: "Failed to read response from server"))
                }
                RedisResponse.readResponse(client: client, timeoutSeconds: timeoutSeconds, callback: callback)
            }
        }
    }
    
    static func readElements(client: RedisClient, count: Int, into: [RedisResponse], arrayCallback: @escaping (RedisResponse) -> ()) {
        if count == 0 {
            return arrayCallback(.array(into))
        }
        RedisResponse.readResponse(client: client, timeoutSeconds: redisNetTimeout) {
            element in
            
            if case .error = element {
                return arrayCallback(element)
            }
            
            var newAry = into
            newAry.append(element)
            
            RedisResponse.readElements(client: client, count: count - 1, into: newAry, arrayCallback: arrayCallback)
        }
    }
}

public struct RedisClientIdentifier {
    let host: String
    let port: Int
    let password: String
    let netGenerator: () -> NetTCP
    
    public init() {
        self.host = "127.0.0.1"
        self.port = redisDefaultPort
        self.password = ""
        self.netGenerator = { return NetTCP() }
    }
    
    public init(withHost: String, port: Int, password: String = "", netGenerator: @escaping () -> NetTCP = { return NetTCP() }) {
        self.host = withHost
        self.port = port
        self.password = password
        self.netGenerator = netGenerator
    }
}

public class RedisClient {
    
    public typealias redisResponseCallback = (RedisResponse) -> ()
    
    public enum RedisValue {
        case string(String)
        case binary([UInt8])
        
        func toString() -> String {
            switch self {
            case .string(let s):
                //FIXME:- set 空字符串时会失败
                if s == "" {
                    return "\"NULL\""
                }
                return "\"\(s)\""
            case .binary(let b) : return "\"\(hexString(fromArray: b))\""
            }
        }
    }
    
    public static func getClient(withIdentifier: RedisClientIdentifier, callback: @escaping (() throws -> RedisClient) -> ()) {
        // !FIX! would look in cache here
        let net = withIdentifier.netGenerator()
        do {
            try net.connect(address: withIdentifier.host, port: UInt16(withIdentifier.port), timeoutSeconds: redisNetTimeout) {
                net in
                if let n = net {
                    let client = RedisClient(net: n)
                    if !withIdentifier.password.isEmpty {
                        client.auth(withPassword: withIdentifier.password) {
                            response in
                            guard response.isSimpleOK else {
                                return callback({ throw PerfectNetError.networkError(401, "Not authorized") })
                            }
                            callback({ return client })
                        }
                    } else {
                        callback({ return client })
                    }
                } else {
                    callback({ throw PerfectNetError.networkError(404, "Server was not available") })
                }
            }
        } catch let e {
            callback({ throw e })
        }
    }
    
    public static func releaseClient(_ client: RedisClient) {
        // !FIX! would put back in cache here - check if connection is open
        client.close()
    }
    
    let net: NetTCP
    var readBuffer = [UInt8]()
    var readBufferOffset = 0
    
    var availableBufferedBytes: Int {
        return self.readBuffer.count - self.readBufferOffset
    }
    
    init(net: NetTCP) {
        self.net = net
    }
    
    func close() {
        self.net.close()
    }
    
    func appendCRLF(to: [UInt8]) -> [UInt8] {
        var a = to
        a.append(cr)
        a.append(lf)
        return a
    }
    
    func commandBytes(name: String, parameters: [RedisResponse]) -> [UInt8] {
        var a = name.bytes
        
        for param in parameters {
            a.append(sp)
            a.append(contentsOf: param.toBytes())
        }
        
        return self.appendCRLF(to: a)
    }
    
    func commandBytes(name: String) -> [UInt8] {
        return self.appendCRLF(to: name.bytes)
    }
    
    func sendCommand(name: String, parameters: [RedisResponse], callback: @escaping redisResponseCallback) {
        let a = self.commandBytes(name: name, parameters: parameters)
        self.sendRawCommand(bytes: a, callback: callback)
    }
    
    func sendCommand(name: String, callback: @escaping redisResponseCallback) {
        let a = self.commandBytes(name: name)
        self.sendRawCommand(bytes: a, callback: callback)
    }
    
    // sends the bytes to trhe client
    // reads response when the bytes have been sent
    func sendRawCommand(bytes: [UInt8], callback: @escaping redisResponseCallback) {
        self.net.write(bytes: bytes) {
            wrote in
            
            guard wrote == bytes.count else {
                return callback(.error(type: "NET", msg: "Failed to write all bytes"))
            }
            
            self.readResponse(callback: callback)
        }
    }
    
    func readResponse(callback: @escaping redisResponseCallback) {
        RedisResponse.readResponse(client: self, timeoutSeconds: redisNetTimeout, callback: callback)
    }
    
    // pull the request number of bytes from the buffer
    func extractBytesFromBuffer(size: Int, callback: @escaping ([UInt8]?) -> ()) {
        if self.availableBufferedBytes >= size {
            let ary = Array(self.readBuffer[self.readBufferOffset..<self.readBufferOffset+size])
            self.readBufferOffset += size
            self.trimReadBuffer()
            callback(ary)
        } else {
            self.fillBuffer(timeoutSeconds: redisNetTimeout) {
                ok in
                if ok {
                    self.extractBytesFromBuffer(size: size, callback: callback)
                } else {
                    callback(nil)
                }
            }
        }
    }
    
    // returns nil if there is not a complete line to read
    func pullLineFromBuffer() -> [UInt8]? {
        
        var startOffset = self.readBufferOffset
        let endCount = self.readBuffer.count - 1 // so we can always include the lf
        
        if endCount <= 0 {
            return nil
        }
        
        while startOffset < endCount {
            if self.readBuffer[startOffset] == cr && self.readBuffer[1 + startOffset] == lf {
                let ret = self.readBuffer[self.readBufferOffset..<startOffset]
                self.readBufferOffset = startOffset + 2
                return Array(ret)
            } else {
                startOffset += 1
            }
        }
        return nil
    }
    
    func trimReadBuffer() {
        if self.readBufferOffset > 0 {
            self.readBuffer.removeFirst(self.readBufferOffset)
            self.readBufferOffset = 0
        }
    }
    
    func appendToReadBuffer(bytes: [UInt8]) {
        self.trimReadBuffer()
        self.readBuffer.append(contentsOf: bytes)
    }
    
    // bool indicates that at least one byte was read before timing out
    func fillBuffer(timeoutSeconds: Double, callback: @escaping (Bool) -> ()) {
        self.net.readSomeBytes(count: redisDefaultReadSize) {
            readBytes in
            guard let readBytes = readBytes else {
                return callback(false)
            }
            if readBytes.count == 0 {
                // no data was available now. try with timeout
                self.net.readBytesFully(count: 1, timeoutSeconds: timeoutSeconds) {
                    readBytes in
                    guard let readBytes = readBytes else {
                        return callback(false)
                    }
                    self.appendToReadBuffer(bytes: readBytes)
                    callback(true)
                }
            } else {
                self.appendToReadBuffer(bytes: readBytes)
                callback(true)
            }
        }
    }
}

/// Connection related operations
public extension RedisClient {
    
    /// Authorize with password
    func auth(withPassword: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "AUTH \(withPassword)", callback: callback)
    }
    
    /// Ping the server
    func ping(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PING", callback: callback)
    }
}

/// Database meta-operations
public extension RedisClient {
    
    /// Flush all keys.
    func flushAll(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "FLUSHALL", callback: callback)
    }
    
    /// Save the database sync.
    func save(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SAVE", callback: callback)
    }
    
    /// Save the database async.
    func backgroundSave(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BGSAVE", callback: callback)
    }
    
    /// Timestamp of the last save.
    func lastSave(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LASTSAVE", callback: callback)
    }
    
    /// Timestamp of the last save.
    func rewriteAppendOnlyFile(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BGREWRITEAOF", callback: callback)
    }
    
    /// Number of keys in the database.
    func dbSize(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "DBSIZE", callback: callback)
    }
    
    /// Returns the keys matching pattern.
    func keys(pattern: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "KEYS \(pattern)", callback: callback)
    }
    
    /// Returns a random key from the database.
    func randomKey(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RANDOMKEY", callback: callback)
    }
    
    /// Select the database at index.
    func select(index: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SELECT \(index)", callback: callback)
    }
}

/// Client operations
public extension RedisClient {
    
    /// Indicates the type of clients to kill.
    enum KillFilter {
        case addr(ip: String, port: Int)
        case id(String)
        case typeNormal, typeMaster, typeSlave, typePubSub
        
        func toString() -> String {
            switch self {
            case .addr(let ip, let port):
                return "ADDR \(ip):\(port)"
            case .id(let id):
                return "ID \(id)"
            case .typeNormal:
                return "TYPE normal"
            case .typeMaster:
                return "TYPE master"
            case .typeSlave:
                return "TYPE slave"
            case .typePubSub:
                return "TYPE pubsub"
                
            }
        }
    }
    
    /// Client reply setting.
    enum ReplyType {
        case on, off, skip
        
        func toString() -> String {
            switch self {
            case .on: return "ON"
            case .off: return "OFF"
            case .skip: return "SKIP"
            }
        }
    }
    
    /// List connected clients.
    func clientList(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "CLIENT LIST", callback: callback)
    }
    
    /// Get the name of the connected client.
    func clientGetName(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "CLIENT GETNAME", callback: callback)
    }
    
    /// Set the name of the connected client.
    func clientSetName(to: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "CLIENT SETNAME \(to)", callback: callback)
    }
    
    /// Kill the indicated client connection(s).
    func clientKill(filters: [KillFilter], skipMe: Bool = true, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "CLIENT KILL \(filters.map { $0.toString() }.joined(separator: " ")) SKIPME \(skipMe ? "yes" : "no")", callback: callback)
    }
    
    /// Pause all client activity for the indicated timeout.
    func clientPause(timeoutSeconds: Double, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "CLIENT PAUSE \(Int(timeoutSeconds * 1000))", callback: callback)
    }
    
    /// Adjust client replies.
    func clientReply(type: ReplyType, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "CLIENT REPLY \(type.toString())", callback: callback)
    }
}

/// Key/value get/set operations.
public extension RedisClient {
    
    /// Set the key to the String value with an optional expiration.
    func set(key: String, value: RedisValue, expires: Double = 0.0, ifNotExists: Bool = false, ifExists: Bool = false, callback: @escaping redisResponseCallback) {
        var options = ""
        if expires != 0.0 {
            options += " PX \(Int(expires * 1000))"
        }
        if ifNotExists {
            options += " NX"
        } else if ifExists {
            options += " XX"
        }
        let cmd = "SET \(key) ''\(options)"
        //print("set: \(cmd)")
        self.sendCommand(name: "SET \(key) ''\(options)", callback: callback)
        //self.sendCommand(name: "SET \(key) \(value.toString())\(options)", callback: callback)
    }
    
    /// Set the keys/values.
    func set(keysValues: [(String, RedisValue)], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "MSET \(keysValues.map { "\($0.0) \($0.1.toString())" }.joined(separator: " "))", callback: callback)
    }
    
    /// Set the keys/values.
    func setIfNonExists(keysValues: [(String, RedisValue)], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "MSETNX \(keysValues.map { "\($0.0) \($0.1.toString())" }.joined(separator: " "))", callback: callback)
    }
    
    /// Get the key value.
    func get(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "GET \(key)", callback: callback)
    }
    
    /// Get the keys values.
    func get(keys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "MGET \(keys.joined(separator: " "))", callback: callback)
    }
    
    /// Get the key value and set to new value.
    func getSet(key: String, newValue: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "GETSET \(key) \(newValue.toString())", callback: callback)
    }
    
    /// Get the key value.
    func delete(keys: String..., callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "DEL \(keys.joined(separator: " "))", callback: callback)
    }
    
    /// Increment the key value.
    func increment(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "INCR \(key)", callback: callback)
    }
    
    /// Increment the key value.
    func increment(key: String, by: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "INCRBY \(key) \(by)", callback: callback)
    }
    
    /// Increment the key value.
    func increment(key: String, by: Double, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "INCRBYFLOAT \(key) \(by)", callback: callback)
    }
    
    /// Decrement the key value.
    func decrement(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "DECR \(key)", callback: callback)
    }
    
    /// Increment the key value.
    func decrement(key: String, by: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "DECRBY \(key) \(by)", callback: callback)
    }
    
    /// Rename a key.
    func rename(key: String, newKey: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RENAME \(key) \(newKey)", callback: callback)
    }
    
    /// Rename a key if new name does not exist.
    func renameIfnotExists(key: String, newKey: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RENAMENX \(key) \(newKey)", callback: callback)
    }
    
    /// Check if the indicated keys exist.
    func exists(keys: String..., callback: @escaping redisResponseCallback) {
        guard keys.count > 0 else {
            return callback(.array([RedisResponse]()))
        }
        self.sendCommand(name: "EXISTS \(keys.joined(separator: " "))", callback: callback)
    }
    
    /// Append a value to the key.
    func append(key: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "APPEND \(key) \(value.toString())", callback: callback)
    }
    
    /// Set the expiration for the indicated key.
    func expire(key: String, seconds: Double, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PEXPIRE \(key) \(Int(seconds * 1000))", callback: callback)
    }
    
    /// Set the expiration for the indicated key.
    func expireAt(key: String, seconds: Double, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PEXPIREAT \(key) \(Int(seconds * 1000))", callback: callback)
    }
    
    /// Returns the expiration in milliseconds for the indicated key.
    func timeToExpire(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PTTL \(key)", callback: callback)
    }
    
    /// Remove the expiration for the indicated key.
    func persist(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PERSIST \(key)", callback: callback)
    }
}

/// Bit related operations.
public extension RedisClient {
    
    /// BITFIELD operation integer types.
    enum IntegerType {
        case signed(Int)
        case unsigned(Int)
        
        func toString() -> String {
            switch self {
            case .signed(let i):
                return "i\(i)"
            case .unsigned(let i):
                return "u\(i)"
            }
        }
    }
    
    /// BITFIELD operation commands.
    enum SubCommand {
        case get(type: IntegerType, offset: Int)
        case set(type: IntegerType, offset: Int, value: Int)
        case setMul(type: IntegerType, offset: String, value: Int)
        case incrby(type: IntegerType, offset: Int, increment: Int)
        case overflowWrap
        case overflowSat
        case overflowFail
        
        func toString() -> String {
            switch self {
            case .get(let type, let offset):
                return "GET \(type.toString()) \(offset)"
            case .set(let type, let offset, let value):
                return "SET \(type.toString()) \(offset) \(value)"
            case .setMul(let type, let offset, let value):
                return "SET \(type.toString()) #\(offset) \(value)"
            case .incrby(let type, let offset, let increment):
                return "INCRBY \(type.toString()) \(offset) \(increment)"
            case .overflowWrap:
                return "OVERFLOW WRAP"
            case .overflowSat:
                return "OVERFLOW SAT"
            case .overflowFail:
                return "OVERFLOW FAIL"
            }
        }
    }
    
    /// BITOP bit operations.
    enum BitOperation {
        case and, or, xor, not
        func toString() -> String {
            switch self {
            case .and: return "AND"
            case .or: return "OR"
            case .xor: return "XOR"
            case .not: return "NOT"
            }
        }
    }
    
    /// Count the set bits in a value.
    func bitCount(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITCOUNT \(key)", callback: callback)
    }
    
    /// Count the set bits in a value.
    func bitCount(key: String, start: Int, end: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITCOUNT \(key) \(start) \(end)", callback: callback)
    }
    
    /// Perform a bitfield operation on a value
    func bitField(key: String, commands: [SubCommand], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITFIELD \(key) \(commands.map { $0.toString() }.joined(separator: " "))", callback: callback)
    }
    
    /// Perform a bitfield operation on a value.
    func bitOp(_ op: BitOperation, destKey: String, srcKeys: String..., callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITOP \(op.toString()) \(destKey) \(srcKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Perform a bitpos operation.
    func bitPos(key: String, position: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITPOS \(key) \(position))", callback: callback)
    }
    
    /// Perform a bitpos operation on a range.
    func bitPos(key: String, position: Int, start: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITPOS \(key) \(position) \(start))", callback: callback)
    }
    
    /// Perform a bitpos operation on a range.
    func bitPos(key: String, position: Int, start: Int, end: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BITPOS \(key) \(position) \(start) \(end))", callback: callback)
    }
    
    /// Get the bit at the indicated offset.
    func bitGet(key: String, offset: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "GETBIT \(key) \(offset))", callback: callback)
    }
    
    /// Set the bit at the indicated offset.
    func bitSet(key: String, offset: Int, value: Bool, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SETBIT \(key) \(offset) \(value ? 1 : 0))", callback: callback)
    }
}

/// List related operations
public extension RedisClient {
    
    /// Push values to the beginning of the list
    func listPrepend(key: String, values: [RedisValue], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LPUSH \(key) \(values.map { $0.toString() }.joined(separator: " "))", callback: callback)
    }
    
    /// Push values to the end of the list
    func listAppend(key: String, values: [RedisValue], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RPUSH \(key) \(values.map { $0.toString() }.joined(separator: " "))", callback: callback)
    }
    
    /// Push value to the beginning of the list. LPUSHX
    func listPrependX(key: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LPUSHX \(key) \(value.toString())", callback: callback)
    }
    
    /// Push value to the end of the list. RPUSHX
    func listAppendX(key: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RPUSHX \(key) \(value.toString())", callback: callback)
    }
    
    /// Pop and return the first element from the list
    func listPopFirst(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LPOP \(key)", callback: callback)
    }
    
    /// Pop and return the last element from the list
    func listPopLast(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RPOP \(key)", callback: callback)
    }
    
    /// Pop and return the first element from the list
    func listPopFirstAppend(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LPOP \(key)", callback: callback)
    }
    
    /// Pop and return the last element from the list. Append the element to the destination list.
    func listPopLastAppend(sourceKey: String, destKey: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "RPOPLPUSH \(sourceKey) \(destKey)", callback: callback)
    }
    
    /// Pop and return the last element from the list. Append the element to the destination list.
    func listPopLastAppendBlocking(sourceKey: String, destKey: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BRPOPLPUSH \(sourceKey) \(destKey)", callback: callback)
    }
    
    /// Pop and return the first element from the list
    func listPopFirstBlocking(keys: String..., timeout: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BLPOP \(keys.joined(separator: " ")) \(timeout)", callback: callback)
    }
    
    /// Pop and return the last element from the list
    func listPopLastBlocking(keys: String..., timeout: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "BRPOP \(keys.joined(separator: " ")) \(timeout)", callback: callback)
    }
    
    /// The length of the list
    func listLength(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LLEN \(key)", callback: callback)
    }
    
    /// Remove the items in the range
    func listTrim(key: String, start: Int, stop: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LTRIM \(key) \(start) \(stop)", callback: callback)
    }
    
    /// Returns the list items in the indicated range
    func listRange(key: String, start: Int, stop: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LRANGE \(key) \(start) \(stop)", callback: callback)
    }
    
    /// Returns the list item at the indicated offset.
    func listGetElement(key: String, index: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LINDEX \(key) \(index)", callback: callback)
    }
    
    /// Inserts the new item before the indicated value.
    func listInsert(key: String, element: RedisValue, before: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LINSERT \(key) BEFORE \(before.toString())", callback: callback)
    }
    
    /// Inserts the new item after the indicated value.
    func listInsert(key: String, element: RedisValue, after: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LINSERT \(key) AFTER \(after.toString())", callback: callback)
    }
    
    /// Set the item at index to value.
    func listSet(key: String, index: Int, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LSET \(key) \(index) \(value.toString())", callback: callback)
    }
    
    /// Remove the first N elements matching value.
    func listRemoveMatching(key: String, value: RedisValue, count: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "LREM \(key) \(count) \(value.toString())", callback: callback)
    }
    
}

/// Multi (transaction) related operations.
public extension RedisClient {
    
    /// Begin a transaction.
    func multiBegin(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "MULTI", callback: callback)
    }
    
    /// Execute a transation.
    func multiExec(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "EXEC", callback: callback)
    }
    
    /// Discard a transaction.
    func multiDiscard(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "DISCARD", callback: callback)
    }
    
    /// Watch keys for modification during a transaction.
    func multiWatch(keys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "WATCH \(keys.joined(separator: " "))", callback: callback)
    }
    
    /// Unwatch keys for modification during a transaction.
    func multiUnwatch(callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "UNWATCH", callback: callback)
    }
}

/// Pub/sub related operations.
public extension RedisClient {
    
    /// Subscribe to the following patterns.
    func subscribe(patterns: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PSUBSCRIBE \(patterns.joined(separator: " "))", callback: callback)
    }
    /// Subscribe to the following channels.
    func subscribe(channels: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SUBSCRIBE \(channels.joined(separator: " "))", callback: callback)
    }
    
    /// Unsubscribe to the following patterns.
    func unsubscribe(patterns: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PUNSUBSCRIBE \(patterns.joined(separator: " "))", callback: callback)
    }
    
    /// Unsubscribe to the following channels.
    func unsubscribe(channels: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "UNSUBSCRIBE \(channels.joined(separator: " "))", callback: callback)
    }
    
    /// Publish a message to the channel.
    func publish(channel: String, message: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "PUBLISH \(channel) \(message.toString())", callback: callback)
    }
    
    /// Read a published message given a timeout.
    func readPublished(timeoutSeconds: Double, callback: @escaping redisResponseCallback) {
        RedisResponse.readResponse(client: self, timeoutSeconds: timeoutSeconds, callback: callback)
    }
    
    // PUBSUB
}

/// Set related operations. Write me! !FIX!
public extension RedisClient {
    
    /// Inserts the new elements into the set.
    func setAdd(key: String, elements: [RedisValue], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SADD \(key) \(elements.map { $0.toString() }.joined(separator: " "))", callback: callback)
    }
    
    /// Returns the number of elements in the set.
    func setCount(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SCARD \(key)", callback: callback)
    }
    
    /// Returns the difference between `key` and `againstKeys`.
    func setDifference(key: String, againstKeys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SDIFF \(key) \(againstKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Stores to `into` the difference between `ofKey` and `againstKeys`.
    func setStoreDifference(into: String, ofKey: String, againstKeys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SDIFFSTORE \(into) \(ofKey) \(againstKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Returns the intersection of `key` and `againstKeys`.
    func setIntersection(key: String, againstKeys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SINTER \(key) \(againstKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Stores to `into` the intersection of `ofKey` and `againstKeys`.
    func setStoreIntersection(into: String, ofKey: String, againstKeys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SINTERSTORE \(into) \(ofKey) \(againstKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Returns the union of `key` and `againstKeys`.
    func setUnion(key: String, againstKeys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SUNION \(key) \(againstKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Stores to `into` the union of `ofKey` and `againstKeys`.
    func setStoreUnion(into: String, ofKey: String, againstKeys: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SUNIONSTORE \(into) \(ofKey) \(againstKeys.joined(separator: " "))", callback: callback)
    }
    
    /// Checks if the set `key` contains `value`.
    func setContains(key: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SISMEMBER \(key) \(value.toString())", callback: callback)
    }
    
    /// Returns the members of set `key`.
    func setMembers(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SMEMBERS \(key)", callback: callback)
    }
    
    /// Moves the set `value` `fromKey` to `toKey`.
    func setMove(fromKey: String, toKey: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SMOVE \(fromKey) \(toKey) \(value.toString())", callback: callback)
    }
    
    /// Removes and returns `count` random elements of set `key`.
    func setRandomPop(key: String, count: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SPOP \(key) \(count)", callback: callback)
    }
    
    /// Removes and returns a random element of set `key`.
    func setRandomPop(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SPOP \(key)", callback: callback)
    }
    
    /// Returns `count` random elements of set `key`.
    func setRandomGet(key: String, count: Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SRANDMEMBER \(key) \(count)", callback: callback)
    }
    
    /// Returns a random element of set `key`.
    func setRandomGet(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SRANDMEMBER \(key)", callback: callback)
    }
    
    /// Removes the value from set `key`.
    func setRemove(key: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SREM \(key) \(value.toString())", callback: callback)
    }
    
    /// Removes the values from set `key`.
    func setRemove(key: String, values: [RedisValue], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SREM \(key) \(values.map { $0.toString() }.joined(separator: " "))", callback: callback)
    }
    
    /// Scans the set `key` given the current cursor, which should start from zero.
    /// Optionally accepts a pattern and a maximum returned value count.
    func setScan(key: String, cursor: Int = 0, pattern: String? = nil, count: Int? = nil, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "SSCAN \(key) \(cursor) \(pattern ?? "") \(nil == count ? "" : String(count!))", callback: callback)
    }
}

/// Cluster related operations. Write me! !FIX!
public extension RedisClient {
    
}

/// Command related operations. Write me! !FIX!
public extension RedisClient {
    
}

/// Config related operations. Write me! !FIX!
public extension RedisClient {
    
}

/// Hash related operations. Write me! !FIX!
public extension RedisClient {
    /**
     HDEL key field [field ...]
     
     删除哈希表 key 中的一个或多个指定域，不存在的域将被忽略。
     
     在Redis2.4以下的版本里， HDEL 每次只能删除单个域，如果你需要在一个原子时间内删除多个域，请将命令包含在 MULTI / EXEC 块内。
     可用版本：
     >= 2.0.0
     时间复杂度:
     O(N)， N 为要删除的域的数量。
     返回值:
     被成功移除的域的数量，不包括被忽略的域。
     **/
    func hdel(key: String, fields: [String], callback: @escaping redisResponseCallback) {
        
        self.sendCommand(name: "HDEL \(key) \(arrayToStr(fields))", callback: callback)
    }
    
    /**
     HEXISTS key field
     
     查看哈希表 key 中，给定域 field 是否存在。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(1)
     返回值：
     如果哈希表含有给定域，返回 1 。
     如果哈希表不含有给定域，或 key 不存在，返回 0 。
     **/
    func hexists(key: String, field: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HEXISTS \(key) \(field)", callback: callback)
    }
    
    /**
     HGET key field
     
     返回哈希表 key 中给定域 field 的值。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(1)
     返回值：
     给定域的值。
     当给定域不存在或是给定 key 不存在时，返回 nil 。
     
     **/
    func hget(key: String, field: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HGET \(key) \(field)", callback: callback)
    }
    
    /**
     HGETALL key
     
     返回哈希表 key 中，所有的域和值。
     
     在返回值里，紧跟每个域名(field name)之后是域的值(value)，所以返回值的长度是哈希表大小的两倍。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(N)， N 为哈希表的大小。
     返回值：
     以列表形式返回哈希表的域和域的值。
     若 key 不存在，返回空列表。
     
     **/
    func hgetall(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HGETALL \(key)", callback: callback)
    }
    
    /**
     HINCRBY key field increment
     
     为哈希表 key 中的域 field 的值加上增量 increment 。
     
     增量也可以为负数，相当于对给定域进行减法操作。
     
     如果 key 不存在，一个新的哈希表被创建并执行 HINCRBY 命令。
     
     如果域 field 不存在，那么在执行命令前，域的值被初始化为 0 。
     
     对一个储存字符串值的域 field 执行 HINCRBY 命令将造成一个错误。
     
     本操作的值被限制在 64 位(bit)有符号数字表示之内。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(1)
     返回值：
     执行 HINCRBY 命令之后，哈希表 key 中域 field 的值。
     **/
    func hincrby(key: String, field: String, increment:Int, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HINCRBY \(key) \(field) \(increment)", callback: callback)
    }
    
    /**
     HINCRBYFLOAT key field increment
     
     为哈希表 key 中的域 field 加上浮点数增量 increment 。
     
     如果哈希表中没有域 field ，那么 HINCRBYFLOAT 会先将域 field 的值设为 0 ，然后再执行加法操作。
     
     如果键 key 不存在，那么 HINCRBYFLOAT 会先创建一个哈希表，再创建域 field ，最后再执行加法操作。
     
     当以下任意一个条件发生时，返回一个错误：
     
     域 field 的值不是字符串类型(因为 redis 中的数字和浮点数都以字符串的形式保存，所以它们都属于字符串类型）
     域 field 当前的值或给定的增量 increment 不能解释(parse)为双精度浮点数(double precision floating point number)
     HINCRBYFLOAT 命令的详细功能和 INCRBYFLOAT 命令类似，请查看 INCRBYFLOAT 命令获取更多相关信息。
     
     可用版本：
     >= 2.6.0
     时间复杂度：
     O(1)
     返回值：
     执行加法操作之后 field 域的值。
     **/
    func hincrbyfloat(key: String, field: String, increment:Float, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HINCRBYFLOAT \(key) \(field) \(increment)", callback: callback)
    }
    
    /**
     HKEYS key
     
     返回哈希表 key 中的所有域。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(N)， N 为哈希表的大小。
     返回值：
     一个包含哈希表中所有域的表。
     当 key 不存在时，返回一个空表。
     **/
    func hkeys(pattern: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HKEYS \(pattern)", callback: callback)
    }
    
    /**
     HLEN key
     
     返回哈希表 key 中域的数量。
     
     时间复杂度：
     O(1)
     返回值：
     哈希表中域的数量。
     当 key 不存在时，返回 0 。
     **/
    func hlen(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HLEN \(key)", callback: callback)
    }
    
    /**
     HMGET key field [field ...]
     
     返回哈希表 key 中，一个或多个给定域的值。
     
     如果给定的域不存在于哈希表，那么返回一个 nil 值。
     
     因为不存在的 key 被当作一个空哈希表来处理，所以对一个不存在的 key 进行 HMGET 操作将返回一个只带有 nil 值的表。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(N)， N 为给定域的数量。
     返回值：
     一个包含多个给定域的关联值的表，表值的排列顺序和给定域参数的请求顺序一样。
     **/
    func hmget(key: String, fields: [String], callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HMGET \(key) \(arrayToStr(fields))", callback: callback)
    }
    
    /**
     HMSET key field value [field value ...]
     
     同时将多个 field-value (域-值)对设置到哈希表 key 中。
     
     此命令会覆盖哈希表中已存在的域。
     
     如果 key 不存在，一个空哈希表被创建并执行 HMSET 操作。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(N)， N 为 field-value 对的数量。
     返回值：
     如果命令执行成功，返回 OK 。
     当 key 不是哈希表(hash)类型时，返回一个错误。
     **/
    func hmset(key: String, fields: [String], values:[RedisValue], callback: @escaping redisResponseCallback) {
        let count = fields.count > values.count ? values.count:fields.count
        var s = ""
        for i in 0..<count {
            if i == 0 {
                s = "\(fields[i]) \(values[i].toString())"
            } else {
                s += " \(fields[i]) \(values[i].toString())"
            }
        }
        print("HMSET \(key) \(s)")
        self.sendCommand(name: "HMSET \(key) \(s)", callback: callback)
    }
    
    /**
     HSET key field value
     
     将哈希表 key 中的域 field 的值设为 value 。
     
     如果 key 不存在，一个新的哈希表被创建并进行 HSET 操作。
     
     如果域 field 已经存在于哈希表中，旧值将被覆盖。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(1)
     返回值：
     如果 field 是哈希表中的一个新建域，并且值设置成功，返回 1 。
     如果哈希表中域 field 已经存在且旧值已被新值覆盖，返回 0 。
     **/
    func hset(key: String, field: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HSET \(key) \(field)) \(value.toString())", callback: callback)
    }
    
    /**
     HSETNX key field value
     
     将哈希表 key 中的域 field 的值设置为 value ，当且仅当域 field 不存在。
     
     若域 field 已经存在，该操作无效。
     
     如果 key 不存在，一个新哈希表被创建并执行 HSETNX 命令。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(1)
     返回值：
     设置成功，返回 1 。
     如果给定域已经存在且没有操作被执行，返回 0 。
     **/
    func hsetnx(key: String, field: String, value: RedisValue, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HSET \(key) \(field)) \(value.toString())", callback: callback)
    }
    
    /**
     HVALS key
     
     返回哈希表 key 中所有域的值。
     
     可用版本：
     >= 2.0.0
     时间复杂度：
     O(N)， N 为哈希表的大小。
     返回值：
     一个包含哈希表中所有值的表。
     当 key 不存在时，返回一个空表。
     **/
    func hvals(key: String, callback: @escaping redisResponseCallback) {
        self.sendCommand(name: "HVALS \(key)", callback: callback)
    }
    
    
    private func arrayToStr(_ arr:Array<String>)->String {
        var str = ""
        for (idx,_) in arr.enumerated() {
            if idx == 0 {
                str = arr[idx]
            } else {
                str += " \(arr[idx])"
            }
        }
        return str
    }
}

