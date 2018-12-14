# frozen_string_literal: true

require "i18n"
require 'pry'

require 'net/http'
require 'json'
# require_relative "../callback"
# require_relative "../response"
# require_relative "common"

module Lita
  class Handler
    # A handler mixin that provides the methods necessary for responding to chat messages.
    # @since 4.0.0
    module IntentRouter
      # Includes common handler methods in any class that includes {ChatRouter}.
      def self.extended(klass)
        klass.send(:include, Common)
      end

      # A Struct representing a chat route defined by a handler.
      Route = Struct.new(
        :intent,
        :callback,
        :command,
        :required_groups,
        :help,
        :extensions
      )

      class Route
        alias command? command
      end

      # @overload route(pattern, method_name, **options)
      #   Creates a chat route.
      #   @param pattern [Regexp] A regular expression to match incoming messages against.
      #   @param method_name [Symbol, String] The name of the instance method to trigger.
      #   @param command [Boolean] Whether or not the message must be directed at the robot.
      #   @param restrict_to [Array<Symbol, String>, nil] An optional list of authorization
      #     groups the user must be in to trigger the route.
      #   @param help [Hash] An optional map of example invocations to descriptions.
      #   @param options [Hash] Aribtrary additional data that can be used by Lita extensions.
      #   @return [void]
      # @overload route(pattern, **options)
      #   Creates a chat route.
      #   @param pattern [Regexp] A regular expression to match incoming messages against.
      #   @param command [Boolean] Whether or not the message must be directed at the robot.
      #   @param restrict_to [Array<Symbol, String>, nil] An optional list of authorization
      #     groups the user must be in to trigger the route.
      #   @param help [Hash] An optional map of example invocations to descriptions.
      #   @param options [Hash] Aribtrary additional data that can be used by Lita extensions.
      #   @yield The body of the route's callback.
      #   @return [void]
      #   @since 4.0.0
      def intent(name, method_name = nil, **options, &block)
        options = default_route_options.merge(options)
        options[:restrict_to] = options[:restrict_to].nil? ? nil : Array(options[:restrict_to])
        routes << Route.new(
          name,
          Callback.new(method_name || block),
          options.delete(:command),
          options.delete(:restrict_to),
          options.delete(:help),
          options
        )
      end

      # A list of chat routes defined by the handler.
      # @return [Array<Handler::Route>]
      def routes
        @routes ||= []
      end

      # The main entry point for the handler at runtime. Checks if the message
      # matches any of the routes and invokes the route's method if it does.
      # Called by {Robot#receive}.
      # @param robot [Robot] The currently running robot.
      # @param message [Message] The incoming message.
      # @return [Boolean] Whether or not the message matched any routes.
      def dispatch(robot, message)
        intent = get_intent(message)
        routes.map do |route|
          next unless route_applies?(route, intent, robot)
          log_dispatch(robot, route)

          robot.run_concurrently { dispatch_to_route(route, robot, message) }

          true
        end.any?
      end

      # Dispatch directly to a {Route}, ignoring route conditions.
      # @param route [Route] The route to invoke.
      # @param robot [Robot] The currently running robot.
      # @param message [Message] The incoming message.
      # @return [void]
      # @since 3.3.0
      def dispatch_to_route(route, robot, message)
        response = Response.new(message, route.intent)

        robot.hooks[:trigger_intent].each { |hook| hook.call(response: response, route: route) }
        handler = new(robot)
        route.callback.call(handler, response)
        robot.hooks[:post_intent].each { |hook| hook.call(response: response, route: route) }
        robot.trigger(
          :message_dispatched,
          handler: self,
          route: route,
          message: message,
          robot: robot
        )
      # rubocop:disable RescueStandardError
      rescue => error
        log_error(robot, error, message: message)
      end
      # rubocop:enable RescueStandardError

      private

      # The default options for every chat route.
      def default_route_options
        {
          command: false,
          restrict_to: nil,
          help: {}
        }
      end

      # Determines whether or not an incoming messages should trigger a route.
      def route_applies?(route, intent, robot)
        # RouteValidator.new(self, route, message, robot).call

        if !intent.nil?
          intent.to_sym == route.intent
        end
      end

      # TODO: Extract this to an adapter for different NLU engines
      def get_intent(message)
        uri = URI("http://localhost:5000/parse")
        params = { q: message.body }
        uri.query = URI.encode_www_form(params)

        res = Net::HTTP.get_response(uri)
        if res.is_a?(Net::HTTPSuccess)
          nlu_response = JSON.parse(res.body)
          intent = nlu_response["intent"]["name"]
          intent&.to_sym
        end
      end

      # Logs the dispatch of message.
      def log_dispatch(robot, route)
        robot.logger.debug I18n.t(
          "lita.handler.dispatch",
          handler: name,
          method: route.callback.method_name || "(block)"
        )
      end
    end
  end
end
