# src/apprt/wayland/wayland.cr
module Apprt
  # :nodoc:
  # The Wayland protocol objects apprt adds to GTK's connection, after
  # Ghostty's src/apprt/gtk/winproto/wayland.zig: the globals of a display
  # (`Globals`) and the proxies it creates (`Proxy`). Interfaces are
  # described by `PROTOCOL` and built into libwayland's structs at first
  # use. Use it on the GTK thread only.
  module Wayland
    # Interfaces apprt binds or creates, with the index of each in
    # `PROTOCOL`.
    enum Iface
      Registry
      Compositor
      Region
      Activation
      ActivationToken
      BackgroundEffectManager
      BackgroundEffect
      DecorationManager
      Decoration
      IdleNotifier
      IdleNotification
    end

    # Each interface: wire name, version, request and event signatures in
    # opcode order. Only interfaces apprt owns proxies of are listed; their
    # event lists are complete, since libwayland rejects unknown opcodes.
    PROTOCOL = [
      {name: "wl_registry", version: 1, requests: ["usun"], events: ["usu", "u"]},
      {name: "wl_compositor", version: 4, requests: ["n", "n"], events: [] of String},
      {name: "wl_region", version: 1, requests: ["", "iiii", "iiii"], events: [] of String},
      {name: "xdg_activation_v1", version: 1, requests: ["", "n", "so"], events: [] of String},
      {name: "xdg_activation_token_v1", version: 1, requests: ["uo", "s", "o", "", ""], events: ["s"]},
      {name: "ext_background_effect_manager_v1", version: 1, requests: ["", "no"], events: ["u"]},
      {name: "ext_background_effect_surface_v1", version: 1, requests: ["", "?o"], events: [] of String},
      {name: "org_kde_kwin_server_decoration_manager", version: 1, requests: ["no"], events: ["u"]},
      {name: "org_kde_kwin_server_decoration", version: 1, requests: ["", "u"], events: ["u"]},
      {name: "ext_idle_notifier_v1", version: 1, requests: ["", "nuo"], events: [] of String},
      {name: "ext_idle_notification_v1", version: 1, requests: [""], events: ["", ""]},
    ]

    # Globals bound from the registry; the others are created from them.
    GLOBALS = {Iface::Activation, Iface::BackgroundEffectManager, Iface::DecorationManager, Iface::IdleNotifier}

    # Request opcodes.
    DISPLAY_GET_REGISTRY      = 1_u32
    REGISTRY_BIND             = 0_u32
    COMPOSITOR_CREATE_REGION  = 1_u32
    REGION_DESTROY            = 0_u32
    REGION_ADD                = 1_u32
    ACTIVATION_DESTROY        = 0_u32
    ACTIVATION_GET_TOKEN      = 1_u32
    ACTIVATION_ACTIVATE       = 2_u32
    TOKEN_SET_SURFACE         = 2_u32
    TOKEN_COMMIT              = 3_u32
    TOKEN_DESTROY             = 4_u32
    EFFECT_MANAGER_GET        = 1_u32
    EFFECT_DESTROY            = 0_u32
    EFFECT_SET_BLUR_REGION    = 1_u32
    DECORATION_MANAGER_CREATE = 0_u32
    DECORATION_RELEASE        = 0_u32
    DECORATION_REQUEST_MODE   = 1_u32
    IDLE_NOTIFIER_GET         = 1_u32
    IDLE_NOTIFICATION_DESTROY = 0_u32

    # Event opcodes.
    REGISTRY_GLOBAL             = 0_u32
    EFFECT_MANAGER_CAPABILITIES = 0_u32
    DECORATION_DEFAULT_MODE     = 0_u32
    TOKEN_DONE                  = 0_u32
    IDLE_IDLED                  = 0_u32
    IDLE_RESUMED                = 1_u32

    # `ext_background_effect_manager_v1.capability.blur`.
    CAPABILITY_BLUR = 1_u32

    # Room for every message's arguments.
    private MAX_ARGS = 4

    @@interfaces = Pointer(Wl::Interface).null
    @@globals = {} of Void* => Globals?

    # Returns the libwayland description of *iface*.
    def self.interface(iface : Iface) : Wl::Interface*
      build_interfaces if @@interfaces.null?
      @@interfaces + iface.value
    end

    # Returns the globals of the GDK display *display*, or nil when it is
    # not a Wayland display.
    def self.globals(display : Void*) : Globals?
      @@globals.put_if_absent(display) do
        type = C.gdk_wayland_display_get_type
        Globals.new(display) if C.g_type_check_instance_is_a(display, type) != 0
      end
    end

    # Returns the `wl_surface` of the GDK surface *surface*, or nil when it
    # is not a Wayland surface.
    def self.surface(surface : Void*) : Void*?
      type = C.gdk_wayland_surface_get_type
      return unless C.g_type_check_instance_is_a(surface, type) != 0
      pointer = C.gdk_wayland_surface_get_wl_surface(surface)
      pointer unless pointer.null?
    end

    private def self.build_interfaces : Nil
      interfaces = Pointer(Wl::Interface).malloc(PROTOCOL.size)
      types = Pointer(Wl::Interface*).malloc(MAX_ARGS)
      PROTOCOL.each_with_index do |entry, index|
        requests = messages(entry[:requests], types)
        events = messages(entry[:events], types)
        interfaces[index] = Wl::Interface.new(
          name: entry[:name].to_unsafe, version: entry[:version],
          method_count: entry[:requests].size, methods: requests,
          event_count: entry[:events].size, events: events)
      end
      @@interfaces = interfaces
    end

    # Message names are only used by libwayland's debug output; the
    # signature is enough to marshal and demarshal.
    private def self.messages(signatures : Array(String), types : Wl::Interface**) : Wl::Message*
      return Pointer(Wl::Message).null if signatures.empty?
      list = Pointer(Wl::Message).malloc(signatures.size)
      signatures.each_with_index do |signature, index|
        list[index] = Wl::Message.new(name: "apprt".to_unsafe, signature: signature.to_unsafe, types: types)
      end
      list
    end

    # Calls request *opcode* on the raw proxy *target*; *created* names the
    # interface of the object a `new_id` argument (`NEW_ID`) creates, which
    # is returned with the version of *target*.
    def self.request(target : Void*, opcode : UInt32, args : Tuple, *, created : Iface? = nil,
                     destroy : Bool = false) : Void*
      buffer = uninitialized StaticArray(Wl::Argument, MAX_ARGS)
      args.each_with_index { |arg, index| buffer[index] = argument(arg) }
      interface = created ? interface(created) : Pointer(Wl::Interface).null
      version = Wl.wl_proxy_get_version(target)
      flags = destroy ? Wl::MARSHAL_FLAG_DESTROY : 0_u32
      Wl.wl_proxy_marshal_array_flags(target, opcode, interface, version, flags, buffer.to_unsafe)
    end

    # Placeholder of a `new_id` argument.
    NEW_ID = 0_u32

    def self.argument(value : Int32) : Wl::Argument
      arg = Wl::Argument.new
      arg.i = value
      arg
    end

    def self.argument(value : UInt32) : Wl::Argument
      arg = Wl::Argument.new
      arg.u = value
      arg
    end

    def self.argument(value : String) : Wl::Argument
      arg = Wl::Argument.new
      arg.s = value.to_unsafe
      arg
    end

    def self.argument(value : Void*) : Wl::Argument
      arg = Wl::Argument.new
      arg.o = value
      arg
    end

    def self.argument(value : Proxy) : Wl::Argument
      argument(value.to_unsafe)
    end

    def self.argument(value : Nil) : Wl::Argument
      argument(Pointer(Void).null)
    end

    # Receives the events of a proxy: opcode and arguments.
    alias Listener = Proc(UInt32, Wl::Argument*, Nil)

    # libwayland passes the dispatcher's implementation pointer first.
    private DISPATCH = ->(data : Void*, _target : Void*, opcode : UInt32, _message : Wl::Message*, args : Wl::Argument*) : Int32 do
      begin
        Handles.get(data, Listener).call(opcode, args)
      rescue ex
        Log.error(exception: ex) { "wayland event" }
      end
      0
    end

    # A proxy apprt created, with its event listener.
    class Proxy
      getter to_unsafe : Void*
      getter iface : Iface
      @listener = Pointer(Void).null

      def initialize(@to_unsafe : Void*, @iface : Iface)
      end

      # Calls request *opcode*; see `Wayland.request`.
      def request(opcode : UInt32, *args) : Nil
        Wayland.request(@to_unsafe, opcode, args)
      end

      # Calls request *opcode*, which creates an object of *iface*.
      def create(opcode : UInt32, iface : Iface, *args) : Proxy
        Proxy.new(Wayland.request(@to_unsafe, opcode, args, created: iface), iface)
      end

      # Routes the proxy's events to *block*.
      def listen(&block : UInt32, Wl::Argument* ->) : Nil
        @listener = Handles.retain(Listener.new { |opcode, args| block.call(opcode, args) })
        Wl.wl_proxy_add_dispatcher(@to_unsafe, DISPATCH, @listener, Pointer(Void).null)
      end

      # Sends destructor request *opcode*, or destroys the proxy locally
      # when the interface has none (nil).
      def destroy(opcode : UInt32?) : Nil
        if opcode
          Wayland.request(@to_unsafe, opcode, Tuple.new, destroy: true)
        else
          Wl.wl_proxy_destroy(@to_unsafe)
        end
        Handles.release(@listener) unless @listener.null?
        @listener = Pointer(Void).null
      end

      # Hands the proxy's events to the default queue, which GTK dispatches.
      protected def move_to_default_queue : Nil
        Wl.wl_proxy_set_queue(@to_unsafe, Pointer(Void).null)
      end
    end

    # The extension globals of one Wayland display, bound on a private queue
    # so that GTK's own events are not dispatched while binding.
    class Globals
      getter wl_display : Void*
      getter compositor : Void*
      getter activation : Proxy?
      getter background_effect : Proxy?
      getter decoration : Proxy?
      getter idle_notifier : Proxy?
      getter? blur = false
      # The compositor's preferred `org_kde_kwin_server_decoration` mode.
      getter default_mode : UInt32?

      def initialize(display : Void*)
        @wl_display = C.gdk_wayland_display_get_wl_display(display)
        @compositor = C.gdk_wayland_display_get_wl_compositor(display)
        queue = Wl.wl_display_create_queue(@wl_display)
        wrapper = Wl.wl_proxy_create_wrapper(@wl_display)
        Wl.wl_proxy_set_queue(wrapper, queue)
        registry = Proxy.new(Wayland.request(wrapper, DISPLAY_GET_REGISTRY, {NEW_ID}, created: :registry), :registry)
        Wl.wl_proxy_wrapper_destroy(wrapper)
        offered = {} of String => {UInt32, UInt32}
        registry.listen do |opcode, args|
          next unless opcode == REGISTRY_GLOBAL
          offered[String.new(args[1].s)] = {args[0].u, args[2].u}
        end
        # Roundtrip 1: registry `global` events. Roundtrip 2: first events of
        # the bound globals (blur capabilities, default decoration mode).
        # Then proxies move to GTK's default queue.
        Wl.wl_display_roundtrip_queue(@wl_display, queue)
        bound = GLOBALS.compact_map { |iface| bind(registry, offered, iface) }
        Wl.wl_display_roundtrip_queue(@wl_display, queue)
        bound.each(&.move_to_default_queue)
        registry.destroy(nil)
        Wl.wl_event_queue_destroy(queue)
      end

      private def bind(registry : Proxy, offered : Hash(String, {UInt32, UInt32}), iface : Iface) : Proxy?
        entry = PROTOCOL[iface.value]
        name, version = offered[entry[:name]]? || return
        version = Math.min(version, entry[:version].to_u32)
        # `bind` takes an untyped `new_id`: interface name and version
        # precede the id.
        args = StaticArray[Wayland.argument(name), Wayland.argument(entry[:name]), Wayland.argument(version), Wayland.argument(NEW_ID)]
        pointer = Wl.wl_proxy_marshal_array_flags(registry.to_unsafe, REGISTRY_BIND, Wayland.interface(iface),
          version, 0_u32, args.to_unsafe)
        proxy = Proxy.new(pointer, iface)
        case iface
        when .activation?
          @activation = proxy
        when .background_effect_manager?
          @background_effect = proxy
          proxy.listen { |opcode, args| @blur = args[0].u & CAPABILITY_BLUR != 0 if opcode == EFFECT_MANAGER_CAPABILITIES }
        when .idle_notifier?
          @idle_notifier = proxy
        when .decoration_manager?
          @decoration = proxy
          proxy.listen { |opcode, args| @default_mode = args[0].u if opcode == DECORATION_DEFAULT_MODE }
        end
        proxy
      end
    end
  end
end
