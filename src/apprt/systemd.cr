# src/apprt/systemd.cr
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
