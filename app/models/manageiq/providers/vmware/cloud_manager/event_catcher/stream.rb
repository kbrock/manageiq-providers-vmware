# Listens to RabbitMQ events
class ManageIQ::Providers::Vmware::CloudManager::EventCatcher::Stream
  include Vmdb::Logging

  def self.test_amqp_connection(options = {})
    connection = nil
    begin
      connection = connect(options)
      connection.start
      return true
    rescue Bunny::AuthenticationFailureError
      raise MiqException::MiqInvalidCredentialsError.new "bad username or password for #{options[:hostname]}"
    rescue Bunny::TCPConnectionFailed, Bunny::TCPConnectionFailedForAllHosts
      raise MiqException::MiqHostError.new "cannot reach #{options[:hostname]}:#{options[:port]}"
    rescue
      raise
    ensure
      connection.close if connection.respond_to?(:close) && connection.open?
    end
  end

  def self.connect(connection_options = {})
    require 'bunny'
    Bunny.new(connection_options)
  end

  def self.log_prefix
    "MIQ(#{self.class.name})"
  end

  def initialize(options = {})
    @options          = options
    @client_ip        = @options[:client_ip]
    @collecting_events = false

    # protect threaded access to the events array
    @events_array_mutex = Mutex.new
    @events = []
  end

  def start
    $vcloud_log.debug("Opening amqp connection to #{@options}")
    connection.start
    @channel = connection.create_channel
    initialize_queues(@channel)
  end

  def stop
    @connection.close if @connection.respond_to? :close
    @collecting_events = false
  end

  def each_batch
    @collecting_events = true
    listen_queues
    while @collecting_events
      @events_array_mutex.synchronize do
        yield @events
        @events.clear
      end
      sleep 5
    end
  end

  private

  def connection
    @connection ||= self.class.connect(@options)
  end

  def initialize_queues(channel)
    require 'bunny'
    @queues = {}
    @options[:queues].each do |queue_name|
      begin
        @queues[queue_name] = channel.queue(queue_name, :durable => true)
      rescue Bunny::AccessRefused => err
        $vcloud_log.warn("Could not start listening to queue '#{queue_name}' due to: #{err}")
      end
    end
  end

  def listen_queues
    @queues.each do |queue_name, queue|
      queue.subscribe do |delivery_info, metadata, payload|
        begin

          # Parse amqp message
          event = ManageIQ::Providers::Vmware::CloudManager::EventCatcher::Event.new(payload, metadata, delivery_info)

          # Ignore message if not related to event, see link below
          if event.type.start_with? "com/vmware/vcloud/event/"
            @events_array_mutex.synchronize do
              @events << event
            end
          end
        rescue => e
          $vcloud_log.error("Exception receiving Rabbit (amqp)"\
                     " event on #{queue_name} from #{@options[:hostname]}: #{e}")
        end
      end
    end
  end
end
