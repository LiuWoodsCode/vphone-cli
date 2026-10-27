import AppleMobileDeviceLibrary
import ArgumentParser
import Foundation

/// Internal bridge to MCInstall. A file copy can leave its active cloud
/// configuration empty even when CloudConfigurationDetails.plist is on disk.
struct VPhoneManagementCloudCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "management-cloud-config",
        abstract: "Apply a restored guest cloud configuration through MCInstall",
        shouldDisplay: false,
    )

    @Option var udid: String
    @Option(transform: URL.init(fileURLWithPath:)) var plist: URL

    mutating func run() throws {
        let data = try Data(contentsOf: plist)
        guard let configuration = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              configuration["IsSupervised"] is Bool else {
            throw ValidationError("CloudConfigurationDetails.plist is missing IsSupervised")
        }

        var device: idevice_t?
        guard idevice_new(&device, udid) == IDEVICE_E_SUCCESS, let device else {
            throw ValidationError("The VM's USB device \(udid) is unavailable")
        }
        defer { idevice_free(device) }

        var lockdown: lockdownd_client_t?
        guard lockdownd_client_new_with_handshake(device, &lockdown, "vphone-cli") == LOCKDOWN_E_SUCCESS,
              let lockdown else {
            throw ValidationError("Could not pair with the VM's lockdown service")
        }
        defer { lockdownd_client_free(lockdown) }

        var descriptor: lockdownd_service_descriptor_t?
        guard lockdownd_start_service(lockdown, "com.apple.mobile.MCInstall", &descriptor) == LOCKDOWN_E_SUCCESS,
              let descriptor else {
            throw ValidationError("Could not start the guest's MCInstall service")
        }
        defer { lockdownd_service_descriptor_free(descriptor) }

        var service: property_list_service_client_t?
        guard property_list_service_client_new(device, descriptor, &service) == PROPERTY_LIST_SERVICE_E_SUCCESS,
              let service else {
            throw ValidationError("Could not connect to the guest's MCInstall service")
        }
        defer { property_list_service_client_free(service) }

        let current = try send(["RequestType": "GetCloudConfiguration"], to: service)
        if let cloud = current["CloudConfiguration"] as? [String: Any],
           Self.matchesRestoredConfiguration(cloud, configuration) {
            print("[management] MCInstall already reports the requested cloud configuration")
            return
        }
        let response = try send(
            ["RequestType": "SetCloudConfiguration", "CloudConfiguration": configuration],
            to: service,
        )
        guard response["Status"] as? String == "Acknowledged" else {
            throw ValidationError("MCInstall refused the cloud configuration: \(response)")
        }
        let active = try send(["RequestType": "GetCloudConfiguration"], to: service)
        guard let cloud = active["CloudConfiguration"] as? [String: Any],
              Self.matchesRestoredConfiguration(cloud, configuration) else {
            throw ValidationError("MCInstall did not report the complete restored cloud configuration")
        }
        print("[management] MCInstall applied cloud configuration to \(udid)")
    }

    /// MCInstall converts a local `ConfigurationSource = 0` to 2. All other
    /// keys, including opaque data and nested values, must read back exactly.
    private static func matchesRestoredConfiguration(_ active: [String: Any], _ restored: [String: Any]) -> Bool {
        var expected = restored
        if expected["ConfigurationSource"] as? Int == 0 {
            expected["ConfigurationSource"] = 2
        }
        return expected.allSatisfy { key, value in
            guard let actual = active[key] else { return false }
            return NSDictionary(dictionary: ["value": actual]).isEqual(to: ["value": value])
        }
    }

    private func send(_ request: [String: Any], to service: property_list_service_client_t) throws -> [String: Any] {
        let xml = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        var message: plist_t?
        let parse = xml.withUnsafeBytes { bytes in
            plist_from_xml(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), UInt32(xml.count), &message)
        }
        guard parse == PLIST_ERR_SUCCESS, let message else {
            throw ValidationError("Could not encode an MCInstall request")
        }
        defer { plist_free(message) }
        guard property_list_service_send_xml_plist(service, message) == PROPERTY_LIST_SERVICE_E_SUCCESS else {
            throw ValidationError("Could not send an MCInstall request")
        }
        var reply: plist_t?
        guard property_list_service_receive_plist(service, &reply) == PROPERTY_LIST_SERVICE_E_SUCCESS,
              let reply else {
            throw ValidationError("MCInstall did not answer")
        }
        defer { plist_free(reply) }
        var responseXML: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        guard plist_to_xml(reply, &responseXML, &length) == PLIST_ERR_SUCCESS,
              let responseXML else {
            throw ValidationError("Could not decode the MCInstall response")
        }
        defer { free(responseXML) }
        let responseData = Data(bytes: responseXML, count: Int(length))
        guard let response = try PropertyListSerialization.propertyList(from: responseData, format: nil) as? [String: Any] else {
            throw ValidationError("MCInstall returned an invalid response")
        }
        return response
    }
}
