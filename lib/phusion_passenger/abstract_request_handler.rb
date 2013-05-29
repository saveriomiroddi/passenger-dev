# encoding: binary
#  Phusion Passenger - http://www.modrails.com/
#  Copyright (c) 2010 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  See LICENSE file for license information.

require 'socket'
require 'fcntl'
require 'phusion_passenger'
require 'phusion_passenger/constants'
require 'phusion_passenger/public_api'
require 'phusion_passenger/message_channel'
require 'phusion_passenger/message_client'
require 'phusion_passenger/debug_logging'
require 'phusion_passenger/utils'
require 'phusion_passenger/utils/memory_measurer'
require 'phusion_passenger/utils/tmpdir'
require 'phusion_passenger/utils/unseekable_socket'
require 'phusion_passenger/native_support'

module PhusionPassenger

# The request handler is the layer which connects Apache with the underlying application's
# request dispatcher (i.e. either Rails's Dispatcher class or Rack).
# The request handler's job is to process incoming HTTP requests using the
# currently loaded Ruby on Rails application. HTTP requests are forwarded
# to the request handler by the web server. HTTP responses generated by the
# RoR application are forwarded to the web server, which, in turn, sends the
# response back to the HTTP client.
#
# AbstractRequestHandler is an abstract base class for easing the implementation
# of request handlers for Rails and Rack.
#
# == Design decisions
#
# Some design decisions are made because we want to decrease system
# administrator maintenance overhead. These decisions are documented
# in this section.
#
# === Owner pipes
#
# Because only the web server communicates directly with a request handler,
# we want the request handler to exit if the web server has also exited.
# This is implemented by using a so-called _owner pipe_. The writable part
# of the pipe will be passed to the web server* via a Unix socket, and the web
# server will own that part of the pipe, while AbstractRequestHandler owns
# the readable part of the pipe. AbstractRequestHandler will continuously
# check whether the other side of the pipe has been closed. If so, then it
# knows that the web server has exited, and so the request handler will exit
# as well. This works even if the web server gets killed by SIGKILL.
#
# * It might also be passed to the ApplicationPoolServerExecutable, if the web
#   server's using ApplicationPoolServer instead of StandardApplicationPool.
#
#
# == Request format
#
# Incoming "HTTP requests" are not true HTTP requests, i.e. their binary
# representation do not conform to RFC 2616. Instead, the request format
# is based on CGI, and is similar to that of SCGI.
#
# The format consists of 3 parts:
# - A 32-bit big-endian integer, containing the size of the transformed
#   headers.
# - The transformed HTTP headers.
# - The verbatim (untransformed) HTTP request body.
#
# HTTP headers are transformed to a format that satisfies the following
# grammar:
#
#  headers ::= header*
#  header ::= name NUL value NUL
#  name ::= notnull+
#  value ::= notnull+
#  notnull ::= "\x01" | "\x02" | "\x02" | ... | "\xFF"
#  NUL = "\x00"
#
# The web server transforms the HTTP request to the aforementioned format,
# and sends it to the request handler.
class AbstractRequestHandler
	include DebugLogging
	
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE    = 500
	MAX_HEADER_SIZE = 128 * 1024
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE              = 'IGNORE'              # :nodoc:
	DEFAULT             = 'DEFAULT'             # :nodoc:
	X_POWERED_BY        = 'X-Powered-By'        # :nodoc:
	REQUEST_METHOD      = 'REQUEST_METHOD'      # :nodoc:
	PING                = 'PING'                # :nodoc:
	PASSENGER_CONNECT_PASSWORD  = "PASSENGER_CONNECT_PASSWORD"   # :nodoc:
	MAX_REQUEST_TIME    = 'PASSENGER_MAX_REQUEST_TIME'           # :nodoc:
	
	OBJECT_SPACE_SUPPORTS_LIVE_OBJECTS = ObjectSpace.respond_to?(:live_objects)
	OBJECT_SPACE_SUPPORTS_ALLOCATED_OBJECTS = ObjectSpace.respond_to?(:allocated_objects)
	OBJECT_SPACE_SUPPORTS_COUNT_OBJECTS = ObjectSpace.respond_to?(:count_objects)
	GC_SUPPORTS_TIME = GC.respond_to?(:time)
	GC_SUPPORTS_CLEAR_STATS = GC.respond_to?(:clear_stats)
	
	# A hash containing all server sockets that this request handler listens on.
	# The hash is in the form of:
	#
	#   {
	#      name1 => [socket_address1, socket_type1, socket1],
	#      name2 => [socket_address2, socket_type2, socket2],
	#      ...
	#   }
	#
	# +name+ is a Symbol. +socket_addressx+ is the address of the socket,
	# +socket_typex+ is the socket's type (either 'unix' or 'tcp') and
	# +socketx+ is the actual socket IO objec.
	# There's guaranteed to be at least one server socket, namely one with the
	# name +:main+.
	attr_reader :server_sockets
	
	# Specifies the maximum allowed memory usage, in MB. If after having processed
	# a request AbstractRequestHandler detects that memory usage has risen above
	# this limit, then it will gracefully exit (that is, exit after having processed
	# all pending requests).
	#
	# A value of 0 (the default) indicates that there's no limit.
	attr_accessor :memory_limit
	
	# The number of times the main loop has iterated so far. Mostly useful
	# for unit test assertions.
	attr_reader :iterations
	
	# Number of requests processed so far. This includes requests that raised
	# exceptions.
	attr_reader :processed_requests
	
	# If a soft termination signal was received, then the main loop will quit
	# the given amount of seconds after the last time a connection was accepted.
	# Defaults to 3 seconds.
	attr_accessor :soft_termination_linger_time
	
	# A password with which clients must authenticate. Default is unauthenticated.
	attr_accessor :connect_password
	
	# Create a new RequestHandler with the given owner pipe.
	# +owner_pipe+ must be the readable part of a pipe IO object.
	#
	# Additionally, the following options may be given:
	# - memory_limit: Used to set the +memory_limit+ attribute.
	# - detach_key
	# - connect_password
	# - pool_account_username
	# - pool_account_password_base64
	def initialize(owner_pipe, options = {})
		@server_sockets = {}
		
		if should_use_unix_sockets?
			@main_socket_address, @main_socket = create_unix_socket_on_filesystem
			@server_sockets[:main] = [@main_socket_address, 'unix', @main_socket]
		else
			@main_socket_address, @main_socket = create_tcp_socket
			@server_sockets[:main] = [@main_socket_address, 'tcp', @main_socket]
		end
		
		@http_socket_address, @http_socket = create_tcp_socket
		@server_sockets[:http] = [@http_socket_address, 'tcp', @http_socket]
		
		@owner_pipe = owner_pipe
		@options = options
		@previous_signal_handlers = {}
		@main_loop_generation  = 0
		@main_loop_thread_lock = Mutex.new
		@main_loop_thread_cond = ConditionVariable.new
		@memory_limit          = options["memory_limit"] || 0
		@connect_password      = options["connect_password"]
		@detach_key            = options["detach_key"]
		@pool_account_username = options["pool_account_username"]
		if options["pool_account_password_base64"]
			@pool_account_password = options["pool_account_password_base64"].unpack('m').first
		end
		@analytics_logger      = options["analytics_logger"]
		@iterations         = 0
		@processed_requests = 0
		@soft_termination_linger_time = 3
		@main_loop_running  = false
		@passenger_header   = determine_passenger_header
		
		@debugger = @options["debugger"]
		if @debugger
			@server_sockets[:ruby_debug_cmd] = ["127.0.0.1:#{Debugger.cmd_port}", 'tcp']
			@server_sockets[:ruby_debug_ctrl] = ["127.0.0.1:#{Debugger.ctrl_port}", 'tcp']
		end
		
		#############
		
		@memory_measurer = Utils::MemoryMeasurer.new
		
		@irb_socket_address, @irb_socket = create_unix_socket_on_filesystem
		@server_sockets[:irb] = [@irb_socket_address, 'unix', @irb_socket]
		
		@async_irb_socket_address, @async_irb_socket = create_unix_socket_on_filesystem
		@server_sockets[:async_irb] = [@async_irb_socket_address, 'unix', @async_irb_socket]
		@async_irb_mutex = Mutex.new
	end
	
	# Clean up temporary stuff created by the request handler.
	#
	# If the main loop was started by #main_loop, then this method may only
	# be called after the main loop has exited.
	#
	# If the main loop was started by #start_main_loop_thread, then this method
	# may be called at any time, and it will stop the main loop thread.
	def cleanup
		if @main_loop_thread
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
			end
			@main_loop_thread.join
		end
		@server_sockets.each_value do |value|
			address, type, socket = value
			socket.close rescue nil
			if type == 'unix'
				File.unlink(address) rescue nil
			end
		end
		@owner_pipe.close rescue nil
	end
	
	# Check whether the main loop's currently running.
	def main_loop_running?
		return @main_loop_running
	end
	
	# Enter the request handler's main loop.
	def main_loop
		debug("Entering request handler main loop")
		reset_signal_handlers
		begin
			@graceful_termination_pipe = IO.pipe
			@graceful_termination_pipe[0].close_on_exec!
			@graceful_termination_pipe[1].close_on_exec!
			
			@main_loop_thread_lock.synchronize do
				@main_loop_generation += 1
				@main_loop_running = true
				@main_loop_thread_cond.broadcast
				
				@select_timeout = nil
				
				@selectable_sockets = []
				@server_sockets.each_value do |value|
					socket = value[2]
					@selectable_sockets << socket if socket
				end
				@selectable_sockets << @owner_pipe
				@selectable_sockets << @graceful_termination_pipe[0]
				
				@selectable_sockets.delete(@async_irb_socket)
				start_async_irb_server
			end
			
			install_useful_signal_handlers
			socket_wrapper = Utils::UnseekableSocket.new
			channel        = MessageChannel.new
			buffer         = ''
			
			while true
				@iterations += 1
				if !accept_and_process_next_request(socket_wrapper, channel, buffer)
					trace(2, "Request handler main loop exited normally")
					break
				end
				@processed_requests += 1
				if @memory_limit > 0
					mem_usage = @memory_measurer.measure
					if mem_usage && mem_usage > @memory_limit
						warn "*** Exceeded memory limit of #{@memory_limit} MB; shutting down."
						@graceful_termination_pipe[1].close rescue nil
					end
				end
			end
		rescue EOFError
			# Exit main loop.
			trace(2, "Request handler main loop interrupted by EOFError exception")
		rescue Interrupt
			# Exit main loop.
			trace(2, "Request handler main loop interrupted by Interrupt exception")
		rescue SignalException => signal
			trace(2, "Request handler main loop interrupted by SignalException")
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		rescue Exception => e
			trace(2, "Request handler main loop interrupted by #{e.class} exception")
			raise
		ensure
			debug("Exiting request handler main loop")
			revert_signal_handlers
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
				stop_async_irb_server
				@graceful_termination_pipe[0].close rescue nil
				@selectable_sockets = []
				@main_loop_generation += 1
				@main_loop_running = false
				@main_loop_thread_cond.broadcast
			end
		end
	end
	
	# Start the main loop in a new thread. This thread will be stopped by #cleanup.
	def start_main_loop_thread
		current_generation = @main_loop_generation
		@main_loop_thread = Thread.new do
			begin
				main_loop
			rescue Exception => e
				print_exception(self.class, e)
			end
		end
		@main_loop_thread_lock.synchronize do
			while @main_loop_generation == current_generation
				@main_loop_thread_cond.wait(@main_loop_thread_lock)
			end
		end
	end
	
	# Remove this request handler from the application pool so that no
	# new connections will come in. Then make the main loop quit a few
	# seconds after the last time a connection came in. This all is to
	# ensure that no connections come in while we're shutting down.
	#
	# May only be called while the main loop is running. May be called
	# from any thread.
	def soft_shutdown
		unless @soft_terminated
			@soft_terminated = true
			@select_timeout = @soft_termination_linger_time
			@graceful_termination_pipe[1].close rescue nil
			if @detach_key && @pool_account_username && @pool_account_password
				client = MessageClient.new(@pool_account_username, @pool_account_password)
				begin
					client.detach(@detach_key)
				ensure
					client.close
				end
			end
		end
	end

private
	include Utils
	
	def should_use_unix_sockets?
		# Historical note:
		# There seems to be a bug in MacOS X Leopard w.r.t. Unix server
		# sockets file descriptors that are passed to another process.
		# Usually Unix server sockets work fine, but when they're passed
		# to another process, then clients that connect to the socket
		# can incorrectly determine that the client socket is closed,
		# even though that's not actually the case. More specifically:
		# recv()/read() calls on these client sockets can return 0 even
		# when we know EOF is not reached.
		#
		# The ApplicationPool infrastructure used to connect to a backend
		# process's Unix socket in the helper server process, and then
		# pass the connection file descriptor to the web server, which
		# triggers this kernel bug. We used to work around this by using
		# TCP sockets instead of Unix sockets; TCP sockets can still fail
		# with this fake-EOF bug once in a while, but not nearly as often
		# as with Unix sockets.
		#
		# This problem no longer applies today. The client socket is now
		# created directly in the web server, and the bug is no longer
		# triggered. Nevertheless, we keep this function intact so that
		# if something like this ever happens again, we know why, and we
		# can easily reactivate the workaround. Or maybe if we just need
		# TCP sockets for some other reason.
		
		#return RUBY_PLATFORM !~ /darwin/
		return true
	end

	def create_unix_socket_on_filesystem
		while true
			begin
				if defined?(NativeSupport)
					unix_path_max = NativeSupport::UNIX_PATH_MAX
				else
					unix_path_max = 100
				end
				socket_address = "#{passenger_tmpdir}/backends/ruby.#{generate_random_id(:base64)}"
				socket_address = socket_address.slice(0, unix_path_max - 1)
				socket = UNIXServer.new(socket_address)
				socket.listen(BACKLOG_SIZE)
				socket.close_on_exec!
				File.chmod(0666, socket_address)
				return [socket_address, socket]
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			end
		end
	end
	
	def create_tcp_socket
		# We use "127.0.0.1" as address in order to force
		# TCPv4 instead of TCPv6.
		socket = TCPServer.new('127.0.0.1', 0)
		socket.listen(BACKLOG_SIZE)
		socket.close_on_exec!
		socket_address = "127.0.0.1:#{socket.addr[1]}"
		return [socket_address, socket]
	end

	# Reset signal handlers to their default handler, and install some
	# special handlers for a few signals. The previous signal handlers
	# will be put back by calling revert_signal_handlers.
	def reset_signal_handlers
		Signal.list_trappable.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		trap('HUP', IGNORE)
		PhusionPassenger.call_event(:after_installing_signal_handlers)
	end
	
	def install_useful_signal_handlers
		trappable_signals = Signal.list_trappable
		
		trap(SOFT_TERMINATION_SIGNAL) do
			begin
				soft_shutdown
			rescue => e
				print_exception("Passenger RequestHandler soft shutdown routine", e)
			end
		end if trappable_signals.has_key?(SOFT_TERMINATION_SIGNAL.sub(/^SIG/, ''))
		
		trap('ABRT') do
			raise SignalException, "SIGABRT"
		end if trappable_signals.has_key?('ABRT')
		
		trap('QUIT') do
			output = global_backtrace_report
			warn(output)
			
			filename = "#{passenger_tmpdir}/backend_ruby_backtrace.#{Process.pid}.txt"
			File.open(filename, "w", 0600) do |f|
				f.write(output)
			end
		end if trappable_signals.has_key?('QUIT')
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end

	class IgnoreException < StandardError
	end
	
	def accept_and_process_next_request(socket_wrapper, channel, buffer)
		select_result = select(@selectable_sockets, nil, nil, @select_timeout)
		if select_result.nil?
			# This can only happen after we've received a soft termination
			# signal. No connection was accepted for @select_timeout seconds,
			# so now we quit the main loop.
			trace(2, "Soft termination timeout")
			return false
		end
		
		ios = select_result.first
		if ios.include?(@main_socket)
			trace(3, "Accepting new request on main socket")
			connection = socket_wrapper.wrap(@main_socket.accept)
			channel.io = connection
			headers, input_stream = parse_native_request(connection, channel, buffer)
			full_http_response = false
		elsif ios.include?(@http_socket)
			trace(3, "Accepting new request on HTTP socket")
			connection = socket_wrapper.wrap(@http_socket.accept)
			headers, input_stream = parse_http_request(connection)
			full_http_response = true
		elsif ios.include?(@irb_socket)
			connection = @irb_socket.accept
			start_irb_session(connection)
		else
			# The other end of the owner pipe has been closed, or the
			# graceful termination pipe has been closed. This is our
			# call to gracefully terminate (after having processed all
			# incoming requests).
			if @select_timeout
				# But if @select_timeout is set then it means that we
				# received a soft termination signal. In that case
				# we don't want to quit immediately, but @select_timeout
				# seconds after the last time a connection was accepted.
				#
				# #soft_shutdown not only closes the graceful termination
				# pipe, but it also tells the application pool to remove
				# this process from the pool, which will cause the owner
				# pipe to be closed. So we remove both IO objects
				# from @selectable_sockets in order to prevent the
				# next select call from immediately returning, allowing
				# it to time out.
				@selectable_sockets.delete(@graceful_termination_pipe[0])
				@selectable_sockets.delete(@owner_pipe)
				return true
			else
				if ios.include?(@owner_pipe)
					trace(2, "Owner pipe closed")
				elsif ios.include?(@graceful_termination_pipe[0])
					trace(2, "Graceful termination pipe closed")
				end
				return false
			end
		end
		
		if headers
			prepare_request(headers)
			ignore = false
			begin
				if headers[REQUEST_METHOD] == PING
					process_ping(headers, input_stream, connection)
				else
					process_request(headers, input_stream, connection, full_http_response)
				end
			rescue IgnoreException
				ignore = true
			rescue Exception
				has_error = true
				raise
			ensure
				finalize_request(headers, has_error) if !ignore
			end
		end
		return true
	rescue => e
		if socket_wrapper.source_of_exception?(e)
			# EPIPE is harmless, it just means that the client closed the connection.
			# Other errors might indicate a problem so we print them, but they're
			# probably not bad enough to warrant stopping the request handler.
			if !e.is_a?(Errno::EPIPE)
				print_exception("Passenger RequestHandler's client socket", e)
			end
			return true
		else
			if @analytics_logger && headers && headers[PASSENGER_TXN_ID]
				log_analytics_exception(headers, e)
			end
			raise e
		end
	ensure
		# The 'close_write' here prevents forked child
		# processes from unintentionally keeping the
		# connection open.
		if connection && !connection.closed?
			begin
				connection.close_write
			rescue SystemCallError
			end
			begin
				connection.close
			rescue SystemCallError
			end
		end
		if input_stream && !input_stream.closed?
			input_stream.close rescue nil
		end
	end
	
	# Read the next request from the given socket, and return
	# a pair [headers, input_stream]. _headers_ is a Hash containing
	# the request headers, while _input_stream_ is an IO object for
	# reading HTTP POST data.
	#
	# Returns nil if end-of-stream was encountered.
	def parse_native_request(socket, channel, buffer)
		headers_data = channel.read_scalar(buffer, MAX_HEADER_SIZE)
		if headers_data.nil?
			return
		end
		headers = split_by_null_into_hash(headers_data)
		if @connect_password && headers[PASSENGER_CONNECT_PASSWORD] != @connect_password
			warn "*** Passenger RequestHandler warning: " <<
				"someone tried to connect with an invalid connect password."
			return
		else
			return [headers, socket]
		end
	rescue SecurityError => e
		warn("*** Passenger RequestHandler warning: " <<
			"HTTP header size exceeded maximum.")
		return nil
	end
	
	# Like parse_native_request, but parses an HTTP request. This is a very minimalistic
	# HTTP parser and is not intended to be complete, fast or secure, since the HTTP server
	# socket is intended to be used for debugging purposes only.
	def parse_http_request(socket)
		headers = {}
		
		data = ""
		while data !~ /\r\n\r\n/ && data.size < MAX_HEADER_SIZE
			data << socket.readpartial(16 * 1024)
		end
		if data.size >= MAX_HEADER_SIZE
			warn("*** Passenger RequestHandler warning: " <<
				"HTTP header size exceeded maximum.")
			return nil
		end
		
		data.gsub!(/\r\n\r\n.*/, '')
		data.split("\r\n").each_with_index do |line, i|
			if i == 0
				# GET / HTTP/1.1
				line =~ /^([A-Za-z]+) (.+?) (HTTP\/\d\.\d)$/
				request_method = $1
				request_uri    = $2
				protocol       = $3
				path_info, query_string    = request_uri.split("?", 2)
				headers[REQUEST_METHOD]    = request_method
				headers["REQUEST_URI"]     = request_uri
				headers["QUERY_STRING"]    = query_string || ""
				headers["SCRIPT_NAME"]     = ""
				headers["PATH_INFO"]       = path_info
				headers["SERVER_NAME"]     = "127.0.0.1"
				headers["SERVER_PORT"]     = socket.addr[1].to_s
				headers["SERVER_PROTOCOL"] = protocol
			else
				header, value = line.split(/\s*:\s*/, 2)
				header.upcase!            # "Foo-Bar" => "FOO-BAR"
				header.gsub!("-", "_")    #           => "FOO_BAR"
				if header == "CONTENT_LENGTH" || header == "CONTENT_TYPE"
					headers[header] = value
				else
					headers["HTTP_#{header}"] = value
				end
			end
		end
		
		if @connect_password && headers["HTTP_X_PASSENGER_CONNECT_PASSWORD"] != @connect_password
			warn "*** Passenger RequestHandler warning: " <<
				"someone tried to connect with an invalid connect password."
			return
		else
			return [headers, socket]
		end
	rescue EOFError
		return nil
	end
	
	def process_ping(env, input, output)
		output.write("pong")
	end
	
	def determine_passenger_header
		header = "Phusion Passenger (mod_rails/mod_rack)"
		if @options["show_version_in_header"]
			header << " #{VERSION_STRING}"
		end
		if File.exist?("#{SOURCE_ROOT}/enterprisey.txt") ||
		   File.exist?("/etc/passenger_enterprisey.txt")
			header << ", Enterprise Edition"
		end
		return header
	end
	
	def prepare_request(headers)
		if @analytics_logger && headers[PASSENGER_TXN_ID]
			txn_id = headers[PASSENGER_TXN_ID]
			group_name = headers[PASSENGER_GROUP_NAME]
			union_station_key = headers[PASSENGER_UNION_STATION_KEY]
			log = @analytics_logger.continue_transaction(txn_id, group_name,
				:requests, union_station_key)
			headers[PASSENGER_ANALYTICS_WEB_LOG] = log
			Thread.current[PASSENGER_ANALYTICS_WEB_LOG] = log
			Thread.current[PASSENGER_TXN_ID] = txn_id
			Thread.current[PASSENGER_GROUP_NAME] = group_name
			Thread.current[PASSENGER_UNION_STATION_KEY] = union_station_key
			if OBJECT_SPACE_SUPPORTS_LIVE_OBJECTS
				log.message("Initial objects on heap: #{ObjectSpace.live_objects}")
			end
			if OBJECT_SPACE_SUPPORTS_ALLOCATED_OBJECTS
				log.message("Initial objects allocated so far: #{ObjectSpace.allocated_objects}")
			elsif OBJECT_SPACE_SUPPORTS_COUNT_OBJECTS
				count = ObjectSpace.count_objects
				log.message("Initial objects allocated so far: #{count[:TOTAL] - count[:FREE]}")
			end
			if GC_SUPPORTS_TIME
				log.message("Initial GC time: #{GC.time}")
			end
			log.begin_measure("app request handler processing")
		end
		
		#################
		
		max_request_time = headers[MAX_REQUEST_TIME].to_i
		if max_request_time > 0
			@timer = DeadlineTimer.new
			@timer.start(max_request_time)
		end
	end
	
	def finalize_request(headers, has_error)
		log = headers[PASSENGER_ANALYTICS_WEB_LOG]
		if log && !log.closed?
			exception_occurred = false
			begin
				log.end_measure("app request handler processing", has_error)
				if OBJECT_SPACE_SUPPORTS_LIVE_OBJECTS
					log.message("Final objects on heap: #{ObjectSpace.live_objects}")
				end
				if OBJECT_SPACE_SUPPORTS_ALLOCATED_OBJECTS
					log.message("Final objects allocated so far: #{ObjectSpace.allocated_objects}")
				elsif OBJECT_SPACE_SUPPORTS_COUNT_OBJECTS
					count = ObjectSpace.count_objects
					log.message("Final objects allocated so far: #{count[:TOTAL] - count[:FREE]}")
				end
				if GC_SUPPORTS_TIME
					log.message("Final GC time: #{GC.time}")
				end
				if GC_SUPPORTS_CLEAR_STATS
					# Clear statistics to void integer wraps.
					GC.clear_stats
				end
				Thread.current[PASSENGER_ANALYTICS_WEB_LOG] = nil
			rescue Exception
				# Maybe this exception was raised while communicating
				# with the logging agent. If that is the case then
				# log.close may also raise an exception, but we're only
				# interested in the original exception. So if this
				# situation occurs we must ignore any exceptions raised
				# by log.close.
				exception_occurred = true
				raise
			ensure
				# It is important that the following call receives an ACK
				# from the logging agent and that we don't close the socket
				# connection until the ACK has been received, otherwise
				# the helper agent may close the transaction before this
				# process's openTransaction command is processed.
				begin
					log.close
				rescue
					raise if !exception_occurred
				end
			end
		end
		
		#################
		
		if @timer
			@timer.stop
			@timer.cleanup
			@timer = nil
		end
	end
	
	class IrbContext
		def initialize(channel)
			utility_class = Class.new do
				include Utils
				instance_methods.each do |method|
					public(method)
				end
			end
			@channel = channel
			@mutex   = Mutex.new
			@utils   = utility_class.new
		end
		
		def help
			puts "Available commands:"
			puts
			puts "  backtraces  Show the all threads' backtraces (requires Ruby Enterprise"
			puts "              Edition or Ruby 1.9)."
			puts "  debugger    Enter a ruby-debug console."
			puts "  help        Show this help message."
			return
		end
		
		def puts(*args)
			@mutex.synchronize do
				io = StringIO.new
				io.puts(*args)
				@channel.write('puts', [io.string].pack('m'))
				return nil
			end
		end
		
		def backtraces
			puts @utils.global_backtrace_report
			return nil
		end
	end
	
	def start_irb_session(socket)
		channel = MessageChannel.new(socket)
		irb_context = IrbContext.new(channel)
		
		password = channel.read_scalar
		if password.nil?
			return
		elsif password == @connect_password
			channel.write("ok")
		else
			channel.write("Invalid connect password.")
		end
		
		while !socket.eof?
			code = channel.read_scalar
			break if code.nil?
			begin
				result = irb_context.instance_eval(code, '(passenger-irb)')
				if result.respond_to?(:inspect)
					result_str = "=> #{result.inspect}"
				else
					result_str = "(result object doesn't respond to #inspect)"
				end
			rescue SignalException
				raise
			rescue SyntaxError => e
				result_str = "SyntaxError:\n#{e}"
			rescue Exception => e
				end_of_trace = nil
				e.backtrace.each_with_index do |trace, i|
					if trace =~ /^\(passenger-irb\)/
						end_of_trace = i
						break
					end
				end
				if end_of_trace
					e.set_backtrace(e.backtrace[0 .. end_of_trace])
				end
				result_str = e.backtrace_string("passenger-irb")
			end
			channel.write('end', [result_str].pack('m'))
		end
	end
	
	def start_async_irb_server
		@async_irb_worker_threads = []
		@async_irb_thread = Thread.new do
			begin
				while true
					ios = select([@async_irb_socket, @graceful_termination_pipe[0]]).first
					if ios.include?(@async_irb_socket)
						socket = @async_irb_socket.accept
						@async_irb_mutex.synchronize do
							@async_irb_worker_threads << Thread.new do
								async_irb_worker_main(socket)
							end
						end
					else
						break
					end
				end
			rescue Exception => e
				print_exception("passenger-irb", e)
			end
		end
	end
	
	def async_irb_worker_main(socket)
		start_irb_session(socket)
	rescue Exception => e
		print_exception("passenger-irb", e)
	ensure
		@async_irb_mutex.synchronize do
			@async_irb_worker_threads.delete(Thread.current)
		end
	end
	
	def stop_async_irb_server
		@async_irb_thread.join
		threads = @async_irb_worker_threads
		@async_irb_mutex.synchronize do
			@async_irb_worker_threads = []
		end
		threads.each do |thread|
			thread.terminate
			thread.join
		end
	end
	
	def log_analytics_exception(env, exception)
		log = @analytics_logger.new_transaction(
			env[PASSENGER_GROUP_NAME],
			:exceptions,
			env[PASSENGER_UNION_STATION_KEY])
		begin
			request_txn_id = env[PASSENGER_TXN_ID]
			message = exception.message
			message = exception.to_s if message.empty?
			message = [message].pack('m')
			message.gsub!("\n", "")
			backtrace_string = [exception.backtrace.join("\n")].pack('m')
			backtrace_string.gsub!("\n", "")

			log.message("Request transaction ID: #{request_txn_id}")
			log.message("Message: #{message}")
			log.message("Class: #{exception.class.name}")
			log.message("Backtrace: #{backtrace_string}")
		ensure
			log.close
		end
	end
end

end # module PhusionPassenger
