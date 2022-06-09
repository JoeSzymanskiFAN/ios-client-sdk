import Vapor
import LaunchDarkly

final class SdkController: RouteCollection {
    private var clients: [Int : LDClient] = [:]
    private var clientCounter = 0

    func boot(routes: RoutesBuilder) {
        routes.get("", use: status)
        routes.post("", use: createClient)
        routes.delete("", use: shutdown)

        let clientRoutes = routes.grouped("clients")
        clientRoutes.post(":id", use: executeCommand)
        clientRoutes.delete(":id", use: shutdownClient)
    }

    func status(_ req: Request) -> StatusResponse {
        let capabilities = [
            "client-side",
            "mobile",
            "service-endpoints",
            "tags"
        ]

        return StatusResponse(
            name: "ios-swift-client-sdk",
            capabilities: capabilities)
    }

    func createClient(_ req: Request) throws -> Response {
        let createInstance = try req.content.decode(CreateInstance.self)
        var config = LDConfig(mobileKey: createInstance.configuration.credential)
        config.enableBackgroundUpdates = true
        config.isDebugMode = true

        if let streaming = createInstance.configuration.streaming {
            if let baseUri = streaming.baseUri {
                config.streamUrl = URL(string: baseUri)!
            }

            // TODO(mmk) Need to hook up initialRetryDelayMs
        } else if let polling = createInstance.configuration.polling {
            config.streamingMode = .polling
            if let baseUri = polling.baseUri {
                config.baseUrl = URL(string: baseUri)!
            }
        }

        if let events = createInstance.configuration.events {
            if let baseUri = events.baseUri {
                config.eventsUrl = URL(string: baseUri)!
            }

            if let capacity = events.capacity {
                config.eventCapacity = capacity
            }

            if let enable = events.enableDiagnostics {
                config.diagnosticOptOut = !enable
            }

            if let allPrivate = events.allAttributesPrivate {
                config.allUserAttributesPrivate = allPrivate
            }

            if let globalPrivate = events.globalPrivateAttributes {
                config.privateUserAttributes = globalPrivate.map({ UserAttribute.forName($0) })
            }

            if let flushIntervalMs = events.flushIntervalMs {
                config.eventFlushInterval =  flushIntervalMs
            }

            if let inlineUsers = events.inlineUsers {
                config.inlineUserInEvents = inlineUsers
            }
        }

        if let tags = createInstance.configuration.tags {
            var applicationInfo = ApplicationInfo()
            if let id = tags.applicationId {
                applicationInfo.applicationIdentifier(id)
            }

            if let verision = tags.applicationVersion {
                applicationInfo.applicationVersion(verision)
            }

            config.applicationInfo = applicationInfo
        }

        let clientSide = createInstance.configuration.clientSide

        if let autoAliasingOptOut = clientSide.autoAliasingOptOut {
            config.autoAliasingOptOut = autoAliasingOptOut
        }

        if let evaluationReasons = clientSide.evaluationReasons {
            config.evaluationReasons = evaluationReasons
        }

        if let useReport = clientSide.useReport {
            config.useReport = useReport
        }

        let dispatchSemaphore = DispatchSemaphore(value: 0)
        let startWaitSeconds = (createInstance.configuration.startWaitTimeMs ?? 5_000) / 1_000

        LDClient.start(config:config, user: clientSide.initialUser, startWaitSeconds: startWaitSeconds) { timedOut in
            dispatchSemaphore.signal()
        }

        dispatchSemaphore.wait()

        let client = LDClient.get()!

        self.clientCounter += 1
        self.clients.updateValue(client, forKey: self.clientCounter)

        var headers = HTTPHeaders()
        headers.add(name: "Location", value: "/clients/\(self.clientCounter)")

        let response = Response()
        response.status = .ok
        response.headers = headers

        return response
    }

    func shutdownClient(_ req: Request) throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: Int.self)
        else { throw Abort(.badRequest) }

        guard let client = self.clients[id]
        else { return HTTPStatus.badRequest }

        client.close()
        clients.removeValue(forKey: id)

        return HTTPStatus.accepted
    }

    func executeCommand(_ req: Request) throws -> CommandResponse {
        guard let id = req.parameters.get("id", as: Int.self)
        else { throw Abort(.badRequest) }

        let commandParameters = try req.content.decode(CommandParameters.self)
        guard let client = self.clients[id] else {
            throw Abort(.badRequest)
        }

        switch commandParameters.command {
        case "evaluate":
            let result: EvaluateFlagResponse = try self.evaluate(client, commandParameters.evaluate!)
            return CommandResponse.evaluateFlag(result)
        case "evaluateAll":
            let result: EvaluateAllFlagsResponse = try self.evaluateAll(client, commandParameters.evaluateAll!)
            return CommandResponse.evaluateAll(result)
        case "identifyEvent":
            let semaphore = DispatchSemaphore(value: 0)
            client.identify(user: commandParameters.identifyEvent!.user) {
                semaphore.signal()
            }
            semaphore.wait()
        case "aliasEvent":
            client.alias(context: commandParameters.aliasEvent!.user, previousContext: commandParameters.aliasEvent!.previousUser)
        case "customEvent":
            let event = commandParameters.customEvent!
            client.track(key: event.eventKey, data: event.data, metricValue: event.metricValue)
        case "flushEvents":
            client.flush()
        default:
            throw Abort(.badRequest)
        }

        return CommandResponse.ok
    }

    func evaluate(_ client: LDClient, _ params: EvaluateFlagParameters) throws -> EvaluateFlagResponse {
        switch params.valueType {
        case "bool":
            if case let LDValue.bool(defaultValue) = params.defaultValue {
                if params.detail {
                    let result = client.boolVariationDetail(forKey: params.flagKey, defaultValue: defaultValue)
                    return EvaluateFlagResponse(value: LDValue.bool(result.value), variationIndex: result.variationIndex, reason: result.reason)
                }

                let result = client.boolVariation(forKey: params.flagKey, defaultValue: defaultValue)
                return EvaluateFlagResponse(value: LDValue.bool(result))
            }
            throw Abort(.badRequest, reason: "Failed to convert \(params.valueType) to bool")
        case "int":
            if case let LDValue.number(defaultValue) = params.defaultValue {
                if params.detail {
                    let result = client.intVariationDetail(forKey: params.flagKey, defaultValue: Int(defaultValue))
                    return EvaluateFlagResponse(value: LDValue.number(Double(result.value)), variationIndex: result.variationIndex, reason: result.reason)
                }

                let result = client.intVariation(forKey: params.flagKey, defaultValue: Int(defaultValue))
                return EvaluateFlagResponse(value: LDValue.number(Double(result)))
            }
            throw Abort(.badRequest, reason: "Failed to convert \(params.valueType) to int")
        case "double":
            if case let LDValue.number(defaultValue) = params.defaultValue {
                if params.detail {
                    let result = client.doubleVariationDetail(forKey: params.flagKey, defaultValue: defaultValue)
                    return EvaluateFlagResponse(value: LDValue.number(result.value), variationIndex: result.variationIndex, reason: result.reason)
                }

                let result = client.doubleVariation(forKey: params.flagKey, defaultValue: defaultValue)
                return EvaluateFlagResponse(value: LDValue.number(result), variationIndex: nil, reason: nil)
            }
            throw Abort(.badRequest, reason: "Failed to convert \(params.valueType) to bool")
        case "string":
            if case let LDValue.string(defaultValue) = params.defaultValue {
                if params.detail {
                    let result = client.stringVariationDetail(forKey: params.flagKey, defaultValue: defaultValue)
                    return EvaluateFlagResponse(value: LDValue.string(result.value), variationIndex: result.variationIndex, reason: result.reason)
                }

                let result = client.stringVariation(forKey: params.flagKey, defaultValue: defaultValue)
                return EvaluateFlagResponse(value: LDValue.string(result), variationIndex: nil, reason: nil)
            }
            throw Abort(.badRequest, reason: "Failed to convert \(params.valueType) to string")
        default:
            if params.detail {
                let result = client.jsonVariationDetail(forKey: params.flagKey, defaultValue: params.defaultValue)
                return EvaluateFlagResponse(value: result.value, variationIndex: result.variationIndex, reason: result.reason)
            }

            let result = client.jsonVariation(forKey: params.flagKey, defaultValue: params.defaultValue)
            return EvaluateFlagResponse(value: result, variationIndex: nil, reason: nil)
        }
    }

    func evaluateAll(_ client: LDClient, _ params: EvaluateAllFlagsParameters) throws -> EvaluateAllFlagsResponse {
        let result = client.allFlags

        return EvaluateAllFlagsResponse(state: result)
    }

    func shutdown(_ req: Request) -> HTTPStatus {
        exit(0)
        return HTTPStatus.accepted
    }
}
