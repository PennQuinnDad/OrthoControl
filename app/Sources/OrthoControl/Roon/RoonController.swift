import Foundation
import os

private let log = Logger(subsystem: "com.ericanderson.OrthoControl", category: "Roon")

struct RoonStatus: Sendable {
    let connected: Bool
    let zoneName: String?
    let volume: Double?
    let state: String?
}

@MainActor
final class RoonController {
    private let baseURL = "http://127.0.0.1:9330"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        session = URLSession(configuration: config)
    }

    /// Fire-and-forget command to the Roon extension.
    func sendCommand(_ command: String, count: Int = 1) {
        guard let url = URL(string: "\(baseURL)/command") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["command": command, "count": count]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        Task.detached {
            do {
                let (_, response) = try await self.session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    log.warning("Roon command '\(command)' returned \(http.statusCode)")
                }
            } catch {
                log.warning("Roon command failed: \(error.localizedDescription)")
            }
        }
    }

    /// Check if the Roon extension is reachable and get status.
    func checkStatus() async -> RoonStatus? {
        guard let url = URL(string: "\(baseURL)/status") else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return RoonStatus(
                connected: json["connected"] as? Bool ?? false,
                zoneName: json["zone_name"] as? String,
                volume: json["volume"] as? Double,
                state: json["state"] as? String
            )
        } catch {
            log.warning("Status check failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch all available Roon zones.
    func fetchZones() async -> (zones: [RoonZone], selectedZoneId: String?)? {
        guard let url = URL(string: "\(baseURL)/zones") else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let zonesArray = json["zones"] as? [[String: Any]] else {
                return nil
            }

            let zones = zonesArray.compactMap { z -> RoonZone? in
                guard let id = z["zone_id"] as? String,
                      let name = z["display_name"] as? String else { return nil }
                return RoonZone(zone_id: id, display_name: name, state: z["state"] as? String)
            }

            let selectedId = json["selected_zone_id"] as? String
            return (zones, selectedId)
        } catch {
            log.warning("Zones fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Switch the active Roon zone.
    func selectZone(_ zoneId: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/zone") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["zone_id": zoneId])

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    log.info("Zone switched to \(json["zone_name"] as? String ?? zoneId)")
                }
                return true
            }
            return false
        } catch {
            log.warning("Zone select failed: \(error.localizedDescription)")
            return false
        }
    }
}
