# src/desktop_kit/c/wayland.cr
module DesktopKit
  # :nodoc:
  # The libwayland-client functions `Wayland` builds on. Protocol interfaces
  # are described at runtime (`Wayland::PROTOCOL`), not taken from the
  # library, so no generated protocol code is needed.
  #
  # gtk4-layer-shell must be linked before libwayland-client (it interposes
  # wl_* symbols), and Crystal links the later annotation first. Wrong
  # order: gtk_layer_is_supported returns false.
  @[Link(pkg_config: "wayland-client")]
  @[Link(pkg_config: "gtk4-layer-shell-0")]
  lib Wl
    MARSHAL_FLAG_DESTROY = 1_u32

    struct Message
      name : UInt8*
      signature : UInt8*
      types : Interface**
    end

    struct Interface
      name : UInt8*
      version : Int32
      method_count : Int32
      methods : Message*
      event_count : Int32
      events : Message*
    end

    union Argument
      i : Int32
      u : UInt32
      s : UInt8*
      o : Void*
      n : UInt32
    end

    # The dispatcher is a C function `(data : Void*, target : Void*,
    # opcode : UInt32, message : Message*, args : Argument*) -> Int32`,
    # passed untyped: a program that also binds libwayland-client with
    # structs of its own (crwin) must declare the same signature.
    fun wl_display_create_queue(display : Void*) : Void*
    fun wl_display_roundtrip_queue(display : Void*, queue : Void*) : Int32
    fun wl_display_flush(display : Void*) : Int32
    fun wl_event_queue_destroy(queue : Void*)
    fun wl_proxy_create_wrapper(proxy : Void*) : Void*
    fun wl_proxy_wrapper_destroy(wrapper : Void*)
    fun wl_proxy_set_queue(proxy : Void*, queue : Void*)
    fun wl_proxy_marshal_array_flags(proxy : Void*, opcode : UInt32, interface : Interface*, version : UInt32,
                                     flags : UInt32, args : Argument*) : Void*
    fun wl_proxy_add_dispatcher(proxy : Void*, dispatcher : Void*, dispatcher_data : Void*, data : Void*) : Int32
    fun wl_proxy_get_version(proxy : Void*) : UInt32
    fun wl_proxy_destroy(proxy : Void*)
  end
end
