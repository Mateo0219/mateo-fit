import Foundation
import Security

let args = CommandLine.arguments
let allowed = ["deepseek", "client"]
guard args.count == 3, ["set", "get"].contains(args[1]), allowed.contains(args[2]) else { exit(2) }
let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.mateofit.private-agent", kSecAttrAccount as String:args[2]]
if args[1] == "set" {
  let value = FileHandle.standardInput.readDataToEndOfFile()
  guard value.count >= 16 && value.count < 1024 else { exit(3) }
  let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:value] as CFDictionary)
  if status == errSecItemNotFound {
    var create = query; create[kSecValueData as String] = value
    create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else { exit(4) }
  } else if status != errSecSuccess { exit(5) }
} else {
  var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
  var value: CFTypeRef?
  guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess, let bytes = value as? Data else { exit(6) }
  FileHandle.standardOutput.write(bytes) // Private caller captures this pipe; never print in diagnostics.
}
