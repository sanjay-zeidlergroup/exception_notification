# frozen_string_literal: true

require "action_dispatch"
require "active_support/core_ext/time"
require "json"

module ExceptionNotifier
  class TeamsNotifier < BaseNotifier
    include ExceptionNotifier::BacktraceCleaner

    class MissingController
      def method_missing(*); end
      def respond_to_missing?(*); true; end
    end

    attr_accessor :httparty

    def initialize(options = {})
      super
      @default_options = options
      @httparty = HTTParty
    end

    def call(exception, options = {})
      @options   = options.merge(@default_options)
      @exception = exception
      @backtrace = exception.backtrace ? clean_backtrace(exception) : nil

      @env = @options.delete(:env)

      @application_name = @options.delete(:app_name) || rails_app_name
      @gitlab_url = @options.delete(:git_url)
      @jira_url   = @options.delete(:jira_url)

      @webhook_url = @options.delete(:webhook_url)
      raise ArgumentError, "You must provide 'webhook_url' parameter." unless @webhook_url

      if @env.nil?
        @controller = @request_items = nil
      else
        @controller = @env["action_controller.instance"] || MissingController.new
        @additional_exception_data = @env["exception_notifier.exception_data"]
        request = ActionDispatch::Request.new(@env)

        @request_items = {url: request.original_url,
                          http_method: request.method,
                          ip_address: request.remote_ip,
                          parameters: request.filtered_parameters,
                          timestamp: Time.current}

      end

      payload = adaptive_card_payload

      @options[:body] = payload.to_json
      @options[:headers] ||= {}
      @options[:headers]["Content-Type"] = "application/json"

      @httparty.post(@webhook_url, @options)
    end

    private

    def adaptive_card_payload
      {
        "type" => "AdaptiveCard",
        "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
        "version" => "1.4",
        "body" => card_body,
        "actions" => card_actions
      }
    end

    def card_body
      body = []

      body << header_block
      body << activity_block
      body << message_block
      body << facts_block if facts_block

      body.compact
    end

    def header_block
      {
        "type" => "TextBlock",
        "text" => "⚠️ Exception Occurred in #{env_name} ⚠️",
        "weight" => "bolder",
        "size" => "large"
      }
    end

    def activity_block
      {
        "type" => "TextBlock",
        "text" => activity_title
      }
    end

    def message_block
      {
        "type" => "TextBlock",
        "text" => @exception.message.to_s,
        "wrap" => true,
        "isSubtle" => true
      }
    end

    def facts_block
      facts = []
      facts << request_fact if @request_items
      facts << backtrace_fact if @backtrace
      facts << data_fact if @additional_exception_data

      return nil if facts.empty?

      {
        "type" => "FactSet",
        "facts" => facts
      }
    end

    def request_fact
      {
        "title" => "Request",
        "value" => hash_presentation(@request_items)
      }
    end

    def backtrace_fact(limit = 3)
      {
        "title" => "Backtrace",
        "value" => @backtrace.first(limit).join("\n")
      }
    end

    def data_fact
      {
        "title" => "Data",
        "value" => @additional_exception_data.to_s
      }
    end

    def card_actions
      actions = []
      actions << gitlab_view_link if @gitlab_url
      actions << gitlab_issue_link if @gitlab_url
      actions << jira_issue_link if @jira_url
      actions
    end

    def gitlab_view_link
      {
        "type" => "Action.OpenUrl",
        "title" => "🦊 View in GitLab",
        "url" => "#{@gitlab_url}/#{@application_name}"
      }
    end

    def gitlab_issue_link
      link = [@gitlab_url, @application_name, "issues", "new"].join("/")
      params = {
        "issue[title]" => [
          "[BUG]",
          controller_and_method,
          "(#{@exception.class})",
          @exception.message
        ].compact.join(" ")
      }.to_query

      {
        "type" => "Action.OpenUrl",
        "title" => "🦊 Create Issue in GitLab",
        "url" => "#{link}?#{params}"
      }
    end

    def jira_issue_link
      {
        "type" => "Action.OpenUrl",
        "title" => "Create Jira Issue",
        "url" => "#{@jira_url}/secure/CreateIssue!default.jspa"
      }
    end

     def activity_title
      errors_count = @options[:accumulated_errors_count].to_i

      "#{(errors_count > 1) ? errors_count : "A"} *#{@exception.class}* occurred" +
        (@controller ? " in *#{controller_and_method}*." : ".")
    end

    def controller_and_method
      return "" unless @controller
      "#{@controller.controller_name}##{@controller.action_name}"
    end

    def hash_presentation(hash)
      hash.map { |k, v| "#{k}: #{v}" }.join("\n")
    end

    def rails_app_name
      return unless defined?(Rails) && Rails.respond_to?(:application)

      if ::Gem::Version.new(Rails.version) >= ::Gem::Version.new("6.0")
        Rails.application.class.module_parent_name.underscore
      else
        Rails.application.class.parent_name.underscore
      end
    end

    def env_name
      Rails.env if defined?(Rails) && Rails.respond_to?(:env)
    end
  end
end
