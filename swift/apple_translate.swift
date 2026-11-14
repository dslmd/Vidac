// apple-translate：调用 macOS 26 自带的 Apple Intelligence 本机模型（Foundation Models）。
// 完全离线，不需要 Ollama。由 vidac/translate.py 的 AppleClient 调用。
//
// 用法：
//   apple-translate --check        模型可用时输出 ok 并返回 0；不可用时原因写到 stderr，返回 2。
//                                  原因的格式是 "[代码] 英文句子"，代码是 not-enabled / model-not-ready /
//                                  not-eligible / unavailable 之一，vidac/translate.py 按代码给出处理办法
//   apple-translate                从 stdin 读 JSON {"instructions": "...", "prompt": "..."}，
//                                  译文写到 stdout
// 返回码：0 成功；2 模型不可用；3 这次生成被拒绝或超出上下文（调用方会把这批拆小重试）；
//         4 输入不是合法 JSON；1 其他错误
//
// 编译（install.sh 会做）：swiftc -O -parse-as-library swift/apple_translate.swift -o bin/apple-translate

import Foundation
import FoundationModels

struct Request: Decodable {
    let instructions: String
    let prompt: String
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
    switch reason {
    case .deviceNotEligible:
        return "[not-eligible] This Mac does not support Apple Intelligence"
    case .appleIntelligenceNotEnabled:
        return "[not-enabled] Apple Intelligence is turned off (enable it in System Settings)"
    case .modelNotReady:
        return "[model-not-ready] The Apple Intelligence model has not finished downloading"
    @unknown default:
        return "[unavailable] Apple Intelligence is unavailable"
    }
}

@main
struct AppleTranslate {
    static func main() async {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            fail(describe(reason), code: 2)
        @unknown default:
            fail("[unavailable] Apple Intelligence is unavailable", code: 2)
        }
        if CommandLine.arguments.contains("--check") {
            print("ok")
            exit(0)
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let req = try? JSONDecoder().decode(Request.self, from: data) else {
            fail("Input is not valid JSON", code: 4)
        }

        let session = LanguageModelSession(instructions: req.instructions)
        do {
            let response = try await session.respond(
                to: req.prompt,
                options: GenerationOptions(temperature: 0)
            )
            print(response.content)
            exit(0)
        } catch let error as LanguageModelSession.GenerationError {
            // 安全护栏、上下文超长、语言不支持等。调用方会拆小这一批再试。
            fail("Generation failed: \(error)", code: 3)
        } catch {
            fail("Error: \(error)", code: 1)
        }
    }
}
