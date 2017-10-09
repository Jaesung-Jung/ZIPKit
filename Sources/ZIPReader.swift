//
//  ZIPReader.swift
//
//  Copyright (c) 2017 Jaesung Jung.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import MiniZip

public class ZIPReader {

    public let fileURL: URL
    public let isEncrypted: Bool
    public lazy var files: [ZIPReader.File] = self.readFiles()

    public init?(contentsOf url: URL) {
        guard let handle = unzOpen64(url.path) else {
            return nil
        }
        defer {
            unzClose(handle)
        }
        fileURL = url

        unzGoToFirstFile(handle)
        unzOpenCurrentFile(handle)
        defer {
            unzCloseCurrentFile(handle)
        }

        var buffer: [UInt8] = []
        isEncrypted = unzReadCurrentFile(handle, &buffer, 1) < 0
    }

    public func data(offset: UInt64, password: String? = nil) throws -> Data {
        var data = Data()
        let stream = Stream(url: fileURL, offset: offset, password: password)
        try stream.streaming {
            data.append($0)
            return true
        }
        return data
    }

    public func unarchive(to: URL, password: String? = nil, overwrite: Bool = true) -> Void {
        files.forEach { file in
            let url = to.appendingPathComponent(file.path)
            let directoryURL = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.path) && !overwrite {
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard let stream = OutputStream(toFileAtPath: url.path, append: false) else {
                    return
                }
                stream.open()
                defer {
                    stream.close()
                }
                try file.streaming { data in
                    stream.write(data.withUnsafeBytes { $0 }, maxLength: data.count)
                    return true
                }
            } catch { return }
        }
    }

}

extension ZIPReader {

    private func readFiles() -> [ZIPReader.File] {
        guard let handle = unzOpen64(fileURL.path) else {
            return []
        }
        defer {
            unzClose(handle)
        }

        var files: [File] = []
        unzGoToFirstFile(handle)
        repeat {
            var info = unz_file_info64()
            unzGetCurrentFileInfo64(handle, &info, nil, 0, nil, 0, nil, 0)

            let bufferSize = Int(info.size_filename + 1)
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
            buffer.initialize(to: 0x00, count: bufferSize)
            defer {
                buffer.deallocate(capacity: bufferSize)
            }

            unzGetCurrentFileInfo64(handle, nil, buffer, UInt(bufferSize - 1), nil, 0, nil, 0)

            let path = String(cString: buffer)
            let isDirectory = path.last == "/"
            if !isDirectory {
                let file = File(
                    url: fileURL,
                    path: path,
                    fileExtension: path.pathExtension,
                    isHidden: path.lastPathComponent.first == ".",
                    offset: unzGetOffset64(handle),
                    compressedSize: info.compressed_size,
                    uncompressedSize: info.uncompressed_size,
                    crc: info.crc
                )
                files.append(file)
            }
        } while (unzGoToNextFile(handle) != UNZ_END_OF_LIST_OF_FILE)
        return files
    }

}

extension ZIPReader {

    public enum Error: Swift.Error {
        case invalidPassword
    }

}

extension ZIPReader {

    class Stream {
        let url: URL
        let offset: UInt64
        let password: String?

        init(url: URL, offset: UInt64, password: String? = nil) {
            self.url = url
            self.offset = offset
            self.password = password
        }

        func streaming(_ block: (Data) -> Bool) throws {
            guard let handle = unzOpen64(url.path) else {
                return
            }
            defer {
                unzClose(handle)
            }
            unzSetOffset64(handle, offset)
            if let password = password {
                unzOpenCurrentFilePassword(handle, password)
            } else {
                unzOpenCurrentFile(handle)
            }

            let bufferSize = 65536 // 64kb
            var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate(capacity: bufferSize)
            }

            var readedByte = 0
            var canNext = false
            repeat {
                readedByte = Int(unzReadCurrentFile(handle, buffer, UInt32(bufferSize)))
                if readedByte < 0 {
                    throw Error.invalidPassword
                }
                let data = Data(bytes: buffer, count: readedByte)
                canNext = block(data)
            } while (readedByte > 0 && canNext)
        }
    }

}

extension ZIPReader {

    public struct File: Comparable {
        public let url: URL
        public let path: String
        public let fileExtension: String
        public let isHidden: Bool
        public let offset: UInt64
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let crc: UInt

        public func data(password: String? = nil) throws -> Data {
            var data = Data()
            let stream = Stream(url: url, offset: offset, password: password)
            try stream.streaming {
                data.append($0)
                return true
            }
            return data
        }

        public func streaming(password: String? = nil, streamHandler: (Data) -> Bool) throws {
            let stream = Stream(url: url, offset: offset, password: password)
            try stream.streaming(streamHandler)
        }

        public static func<(lhs: File, rhs: File) -> Bool {
            let l = lhs.path.split(separator: "/")
            let r = rhs.path.split(separator: "/")
            let range = 0..<max(l.count, r.count)
            for index in range {
                if !l.indices.contains(index) {
                    return true
                }
                if !r.indices.contains(index) {
                    return false
                }
                if l[index].lowercased() > r[index].lowercased() {
                    if l.count == 1 && r.count > 1 {
                        return true
                    }
                    return false
                }
                if l[index].lowercased() < r[index].lowercased() {
                    if r.count == 1 && l.count > 1 {
                        return false
                    }
                    return true
                }
            }
            if l.count < r.count {
                return true
            }
            if l.count > r.count {
                return false
            }
            return false
        }

        public static func>(lhs: File, rhs: File) -> Bool {
            return !(lhs < rhs)
        }

        public static func<=(lhs: File, rhs: File) -> Bool {
            return lhs == rhs || lhs < rhs
        }

        public static func>=(lhs: File, rhs: File) -> Bool {
            return lhs == rhs || lhs > rhs
        }

        public static func==(lhs: File, rhs: File) -> Bool {
            return lhs.path == rhs.path
        }
    }

}

extension String {

    var lastPathComponent: String {
        guard last != "/" else {
            return self
        }
        guard let reversedIndex = reversed().index(of: "/") else {
            return self
        }
        return String(self[reversedIndex.base...])
    }

    var pathExtension: String {
        let name = lastPathComponent
        guard let range = name.rangeOfCharacter(from: ["."]) else {
            return String()
        }
        return String(name[range.upperBound...])
    }

}
