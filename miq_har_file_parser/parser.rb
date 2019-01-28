require 'json'

module HarFile
  class Parser
    # Input file (default:  STDIN)
    attr_accessor :input

    # Output file (default: STDOUT)
    attr_accessor :output

    # When generating a template, automatically profile slow requests
    attr_accessor :auto_profile

    # Threshold of what is considered "slow" in milliseconds (default: 10000)
    attr_accessor :auto_profile_threshold

    LOGIN_REQUEST    = %r{/dashboard/authenticate}
    INVALID_REQUESTS = %r{
      /assets|             # assets
      /static|             # static pages
      /dashboard/widget|   # dashboard widgets
      /ws/notifications|   # notifications websocket(?) calls
      /api/notifications|  # notifications fetches
      /api/auth|           # uneeded auth calls
      /api$                # api pings
    }x

    def initialize opts = {}
      @input  = opts[:input]  || STDIN
      @output = opts[:output] || STDOUT

      @auto_profile           = opts[:auto_profile]
      @auto_profile_threshold = opts[:threshold] || 10000
    end

    # Send a formatted summary of the app_requests to the output device
    #
    # Sample Output:
    #
    #     GET     http://localhost:3000/api?attributes=identity
    #     POST    http://localhost:3000/dashboard/authenticate
    #     GET     http://localhost:3000/dashboard/show
    #     GET     http://localhost:3000/vm_cloud/explorer
    #     POST    http://localhost:3000/vm_cloud/report_data
    #
    def summary
      fetch_valid_app_requests.each do |request|
        output.puts "#{request["time"]}\t#{request["method"]}\t#{request["url"]}"
      end
    end

    # Create a `rails runner` script to re-run the recorded requests from the
    # HAR file (input)
    def generate_runner
      require 'uri'
      require 'erb'

      @login_request  = nil
      runner_requests = {}

      app_requests = fetch_valid_app_requests

      # Remove login request from request collection (special, handled
      # separately since it is always required)
      app_requests.delete_if do |request|
        if request["method"] == "POST" && request["url"] =~ LOGIN_REQUEST
          @login_request = request
        end
      end

      generate_runner_requests_from app_requests
      generate_script_from_template
    end

    private

    # Parses the json from the input and brings back only the requests that
    # exercise the backend.
    #
    # Requests that don't fit this criteria are part of the INVALID_REQUESTS
    # Regexp, which is not to say they are "invalid requests for MIQ", but not
    # valid for the purposes of profiling the backend (for example, assets are
    # not something we have to attempt to performance optimize in Rails).
    def fetch_valid_app_requests
      JSON.parse(File.read(@input))["log"]["entries"]
          .reject! { |entry| entry["request"]["url"] =~ INVALID_REQUESTS } 
          .map! do |entry|
            entry["request"]["time"]    = entry["time"]
            entry["request"]["timings"] = entry["timings"]
            entry["request"]
          end
    end

    def auto_profile?
      @auto_profile
    end

    def generate_runner_requests_from requests
      @runner_requests = []

      previous_csrf_token = ""
      requests.each do |request|
        uri = URI.parse(request["url"])

        request_data = {
          :method => request["method"].downcase,
          :path   => "#{uri.path}#{"?" + uri.query if uri.query}"
        }

        # Determine if CSRF_TOKEN should be calculated for this request
        #
        # If we have, cache the value, and re-fetch it in the script only if it
        # has changed.
        csrf_token = (request["headers"].detect do |header|
                       header["name"] == "X-CSRF-Token"
                     end || {})["value"]

        if csrf_token && previous_csrf_token != csrf_token
          request_data[:fetch_new_csrf_token] = true
          previous_csrf_token = csrf_token
        end

        # Add necessary params from postData
        if request["postData"] && request["postData"]["params"]
          request_data[:params] = {}

          request["postData"]["params"].each do |param|
            if param["name"] != "authenticity_token" # TODO:  Determine if this is needed
              request_data[:params][param["name"]] = param["value"]
            end
          end

          request_data.delete(:params) if request_data[:params].empty?
        end

        # Auto benchmark if enabled and recorded request is over threshold
        #
        # Default threshold is 10s (10000 ms)
        if auto_profile? && request["time"] > auto_profile_threshold
          request_data[:benchmark] = true
        end

        @runner_requests << request_data
      end
    end

    def generate_script_from_template
      username, password = nil
      
      @login_request["postData"]["params"].each do |param|
        case param["name"]
        when "user_name"     then username = param["value"]
        when "user_password" then password = param["value"]
        end
      end

      template_binding = binding.dup
      template_binding.local_variable_set :username, username
      template_binding.local_variable_set :password, password
      template_binding.local_variable_set :requests, @runner_requests
      
      write_to_output ERB.new(template, nil, "-").result(template_binding)
    end

    def write_to_output data
      if output == STDOUT
        output.puts data
      else
        File.write output, data
      end
    end

    def template
      <<-'TEMPLATE_ERB'.gsub(/^ {8}/, "")
        # Setup code
        Rails.application.load_console
        Rails.env = ENV["RAILS_ENV"]

        # Include helper methods and call
        include Rails::ConsoleMethods
        toggle_console_sql_logging

        # Avoid errors from UI worker (included in console, but not in runner...)
        MiqUiWorker.preload_for_console

        CSRF_TOKEN_REGEXP = /.*csrf-token.*content="(?<CSRF_TOKEN>[^"]*)"/

        # Intialize base headers
        #
        # Update any request's `:headers => base_headers` to use
        # `benchmark_headers` if you wish to profile the request.
        base_headers      = {}
        perf_headers      = { 
          "HTTP_WITH_PERFORMANCE_MONITORING" => 'true',
          "HTTP_MIQ_PERF_STACKPROF_RAW"      => 'true'
        }

        # Login
        login_params = {
          :user_name     => "<%= username %>",
          :user_password => "<%= password %>"
        }
        app.post "/dashboard/authenticate", :params => login_params


        # Requests to perform once logged in...

        <% requests.each do |request| -%>
        <% if request[:fetch_new_csrf_token] -%>

        # Token change expected, re-calculate csrf_token/base_headers/perf_headers
        csrf_token        = app.response.body.match(CSRF_TOKEN_REGEXP)[:CSRF_TOKEN]
        base_headers      = { "X-CSRF-Token" => csrf_token }
        benchmark_headers = base_headers.merge(perf_headers)
        <% end # if request[:fetch_new_csrf_token] -%>

        <% request_headers = request[:benchmark] ? "benchmark_headers" : "base_headers" -%>
        app.<%= request[:method] %> "<%= request[:path] %>"<%= "," -%>
         :headers => <%= request_headers %><%= "," if request[:params] -%>
         <%= ":params => #{request[:params].inspect}" if request[:params] -%>

        <% end # requests.each -%>
      TEMPLATE_ERB
    end
  end
end
