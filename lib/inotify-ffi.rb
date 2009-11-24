require 'rubygems'
require 'ffi'
module Inotify
  extend FFI::Library

  attach_function :init, :inotify_init, [ ], :int
  attach_function :add_watch, :inotify_add_watch, [ :int, :string, :uint ], :int
  attach_function :rm_watch, :inotify_rm_watch, [ :int, :uint ], :int
  attach_function :read, [ :int, :buffer_out, :uint ], :int

  def self.watch(path, event_mask = IN_ALL_EVENTS)
    Watcher.setup(path, event_mask)
  end

  class Watcher
    def self.setup(path, event_mask)
      new(path, event_mask).setup
    end

    def initialize(path, event_mask)
      @path, @event_mask = path, event_mask
    end
    attr_reader :io

    def setup
      @fd = Inotify.init
      $stderr.puts "fd=#{@fd}"
      @wd = Inotify.add_watch(@fd, @path, @event_mask)
      @io = FFI::IO.for_fd(@fd)
      $stderr.puts "io=#{@io}"
      self
    end

    def each_event
      loop do
        ready = IO.select([ @io ], nil, nil, nil)
        yield Inotify.process_event(@fd)
      end
    end

    def start_em(&block)
      mod = Module.new
      mod.instance_eval do
        include Connection
        define_method(:notify_event) do |ev|
          block.call(ev)
        end
      end
      EM.watch(@io, mod) do |c|
        c.notify_readable = true
      end
    end
  end

  def self.process_event(fd)
    buf = FFI::Buffer.alloc_out(EventStruct.size + 4096, 1, false)
    ev = EventStruct.new(buf)
    n = Inotify.read(fd, buf, buf.total)
    $stderr.puts "Read #{n} bytes from inotify fd"
    Event.new(ev, buf)
  end

  module Connection
    def notify_readable
      notify_event(Inotify.process_event(@fd))
    end

    def notify_event(ev)
      raise "Implement #notify_event on #{self.class}"
    end
  end

  class Event
    def initialize(struct, buf)
      @struct, @buf = struct, buf
    end

    def inspect
      "event.wd=#{@struct[:wd]} mask=#{@struct[:mask]} len=#{@struct[:len]} name=#{name}"
    end

    def mask_names
      Const.constants.select do |const|
        value = Const.const_get(const)
        @struct[:mask] & value > 0
      end
    end

    def name
      @struct[:len] >= 0 ? @buf.get_string(@struct[:len]) : '<unknown>'
    end
  end

  class EventStruct < FFI::Struct
    layout \
      :wd, :int,
      :mask, :uint,
      :cookie, :uint,
      :len, :uint
  end

  module Const
    IN_ACCESS         = 0x00000001
    IN_MODIFY         = 0x00000002
    IN_ATTRIB         = 0x00000004
    IN_CLOSE_WRITE    = 0x00000008
    IN_CLOSE_NOWRITE  = 0x00000010
    IN_OPEN           = 0x00000020
    IN_MOVED_FROM     = 0x00000040
    IN_MOVED_TO       = 0x00000080
    IN_CREATE         = 0x00000100
    IN_DELETE         = 0x00000200
    IN_DELETE_SELF    = 0x00000400
    IN_MOVE_SELF      = 0x00000800
    # Events sent by the kernel.
    IN_UNMOUNT        = 0x00002000
    IN_Q_OVERFLOW     = 0x00004000
    IN_IGNORED        = 0x00008000
    IN_ONLYDIR        = 0x01000000
    IN_DONT_FOLLOW    = 0x02000000
    IN_MASK_ADD       = 0x20000000
    IN_ISDIR          = 0x40000000
    IN_ONESHOT        = 0x80000000
  end
  include Const

  IN_MOVE       = (IN_MOVED_FROM | IN_MOVED_TO)
  IN_CLOSE      = (IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)
  IN_ALL_EVENTS = (IN_ACCESS | IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE \
                    | IN_CLOSE_NOWRITE | IN_OPEN | IN_MOVED_FROM \
                    | IN_MOVED_TO | IN_CREATE | IN_DELETE \
                    | IN_DELETE_SELF | IN_MOVE_SELF)
end

if $0 == __FILE__
######
require 'pp'
require 'eventmachine'

watcher = Inotify.watch("/tmp")
if ENV["EM"]
  module Callback
    include Inotify::Connection

    def notify_event(ev)
      puts ev.inspect
      pp ev.mask_names
    end
  end

  EM.run do
    EM.watch(watcher.io, Callback) do |c|
      c.notify_readable = true
    end
  end
elsif ENV["EM2"]
  EM.run do
    watcher.start_em do |ev|
      puts ev.inspect
      pp ev.mask_names
    end
  end
else
  watcher.each_event do |ev|
    puts ev.inspect
    pp ev.mask_names
  end
end
######
end
