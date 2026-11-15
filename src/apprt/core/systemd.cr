# src/apprt/core/systemd.cr
require "c/sys/socket"
require "c/sys/un"

module Apprt
  # Reports service state to systemd through the `NOTIFY_SOCKET` protocol.
  #
  # `App` reports readiness, reloads and shutdown by itself.
  module Systemd
    # Sends *state*, newline-separated `KEY=value` assignments such as
    # `"STATUS=Indexing"`, and returns whether it was sent.
    #
    # Returns `false` when the process does not run under systemd
    # (`NOTIFY_SOCKET` unset).
    def self.notify(state : String) : Bool
      path = ENV["NOTIFY_SOCKET"]?
      return false if path.nil? || path.empty?
      sun_path = StaticArray(LibC::Char, 108).new(0)
      unless path.starts_with?('/') || path.starts_with?('@')
        Log.warn { "NOTIFY_SOCKET is neither a path nor an abstract socket: #{path}" }
        return false
      end
      if path.bytesize >= sun_path.size
        Log.warn { "NOTIFY_SOCKET is too long: #{path}" }
        return false
      end
      path.to_slice.copy_to(sun_path.to_slice)
      sun_path[0] = 0 if path.starts_with?('@')
      address = LibC::SockaddrUn.new(sun_family: LibC::SaFamilyT.new(LibC::AF_UNIX), sun_path: sun_path)
      length = LibC::SocklenT.new(sizeof(LibC::SaFamilyT) + path.bytesize)
      send(state, pointerof(address).as(LibC::Sockaddr*), length)
    end

    # Moves process *pid* into a new transient scope unit named *unit* of
    # the user's service manager, such as
    # `"app-com.example.App-transient-1234.scope"`, so that systemd accounts
    # and limits its resources apart from the application's.
    #
    # *memory_high* sets the scope's `MemoryHigh` in bytes and *tasks_max*
    # its `TasksMax`; *oom_kill* lets systemd-oomd kill the scope under
    # memory pressure. Blocks up to *timeout* until the process is in the
    # scope and returns whether it is. Raises `GLibError` when the session
    # bus or the service manager fails, such as for a unit name in use.
    def self.start_scope(pid : Int, unit : String, *, memory_high : UInt64? = nil, tasks_max : UInt64? = nil,
                         oom_kill : Bool = false, timeout : Time::Span = 250.milliseconds) : Bool
      properties = [{"PIDs", Variant.new([pid.to_u32])}]
      memory_high.try { |bytes| properties << {"MemoryHigh", Variant.new(bytes)} }
      tasks_max.try { |tasks| properties << {"TasksMax", Variant.new(tasks)} }
      properties << {"ManagedOOMMemoryPressure", Variant.new("kill")} if oom_kill
      message = Variant.new({unit, "fail", properties, [] of {String, Array({String, Variant})}})
      bus = GLibError.check! { |error| C.g_bus_get_sync(C::GBusType::Session, Pointer(Void).null, error) }
      begin
        reply = GLibError.check! do |error|
          C.g_dbus_connection_call_sync(bus, "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager", "StartTransientUnit", message, Pointer(Void).null,
            C::GDBusCallFlags::None, -1, Pointer(Void).null, error)
        end
        C.g_variant_unref(reply)
      ensure
        C.g_object_unref(bus)
      end
      deadline = Time.instant + timeout
      loop do
        return true if cgroup(pid).try(&.ends_with?("/#{unit}"))
        return false if Time.instant >= deadline
        sleep SCOPE_POLL
      end
    end

    # Interval of the checks whether a process joined its scope.
    private SCOPE_POLL = 25.milliseconds

    # Returns the unified cgroup path of process *pid*, or nil when it is
    # gone.
    protected def self.cgroup(pid : Int) : String?
      line = File.open("/proc/#{pid}/cgroup", &.gets)
      line.try(&.split(':', 3)[2]?)
    rescue File::Error
    end

    protected def self.ready : Bool
      notify("READY=1")
    end

    protected def self.reloading : Bool
      LibC.clock_gettime(LibC::CLOCK_MONOTONIC, out now)
      notify("RELOADING=1\nMONOTONIC_USEC=#{now.tv_sec.to_i64 * 1_000_000 + now.tv_nsec.to_i64 // 1_000}")
    end

    protected def self.stopping : Bool
      notify("STOPPING=1")
    end

    private def self.send(state : String, address : LibC::Sockaddr*, length : LibC::SocklenT) : Bool
      fd = LibC.socket(LibC::AF_UNIX, LibC::SOCK_DGRAM | LibC::SOCK_CLOEXEC, 0)
      if fd < 0
        error = Errno.value
        Log.warn { "systemd notify: socket: #{error.message}" }
        return false
      end
      begin
        if LibC.sendto(fd, state.to_unsafe, state.bytesize, 0, address, length) < 0
          error = Errno.value
          Log.warn { "systemd notify: #{error.message}" }
          return false
        end
        true
      ensure
        LibC.close(fd)
      end
    end
  end
end
