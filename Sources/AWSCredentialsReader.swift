import Foundation

class AWSCredentialsReader {
    static let shared = AWSCredentialsReader()
    
    private let credentialsPath: String
    private let configPath: String
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        credentialsPath = "\(homeDir)/.aws/credentials"
        configPath = "\(homeDir)/.aws/config"
    }
    
    struct AWSCredentials {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
        let region: String?
    }
    
    func listProfiles() -> [String] {
        var profiles: Set<String> = []
        
        // Read from credentials file
        if let credContent = try? String(contentsOfFile: credentialsPath, encoding: .utf8) {
            let lines = credContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    let profile = trimmed.dropFirst().dropLast()
                    profiles.insert(String(profile))
                }
            }
        }
        
        // Read from config file
        if let configContent = try? String(contentsOfFile: configPath, encoding: .utf8) {
            let lines = configContent.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[profile ") && trimmed.hasSuffix("]") {
                    let profile = trimmed.dropFirst(9).dropLast()
                    profiles.insert(String(profile))
                } else if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    let profile = trimmed.dropFirst().dropLast()
                    if profile != "default" {
                        profiles.insert(String(profile))
                    }
                }
            }
        }
        
        // Always include default
        profiles.insert("default")
        
        return Array(profiles).sorted()
    }
    
    func getCredentials(profile: String = "default") -> AWSCredentials? {
        guard let credContent = try? String(contentsOfFile: credentialsPath, encoding: .utf8) else {
            return nil
        }
        
        var accessKeyId: String?
        var secretAccessKey: String?
        var sessionToken: String?
        var inProfile = false
        
        let lines = credContent.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check for profile section
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let profileName = trimmed.dropFirst().dropLast()
                inProfile = (profileName == profile)
                continue
            }
            
            // Parse key-value pairs
            if inProfile && trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    let key = parts[0]
                    let value = parts[1]
                    
                    switch key {
                    case "aws_access_key_id":
                        accessKeyId = value
                    case "aws_secret_access_key":
                        secretAccessKey = value
                    case "aws_session_token":
                        sessionToken = value
                    default:
                        break
                    }
                }
            }
        }
        
        // Get region from config
        let region = getRegion(profile: profile)
        
        guard let keyId = accessKeyId, let secretKey = secretAccessKey else {
            return nil
        }
        
        return AWSCredentials(
            accessKeyId: keyId,
            secretAccessKey: secretKey,
            sessionToken: sessionToken,
            region: region
        )
    }
    
    func getRegion(profile: String = "default") -> String? {
        guard let configContent = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        
        var inProfile = false
        let profileSection = profile == "default" ? "default" : "profile \(profile)"
        
        let lines = configContent.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check for profile section
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let section = trimmed.dropFirst().dropLast()
                inProfile = (section == profileSection || section == profile)
                continue
            }
            
            // Parse region
            if inProfile && trimmed.hasPrefix("region") && trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    return parts[1]
                }
            }
        }
        
        return nil
    }
}
