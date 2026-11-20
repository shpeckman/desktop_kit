# src/apprt/window/window_keys.cr
module Apprt
  class Window
    # The most key tables active at once.
    private KEY_TABLE_LIMIT = 8

    @sequence = [] of Trigger
    # Ends the pending sequence after `App#sequence_timeout`; 0 when none
    # runs.
    @sequence_timer = 0_u32
    @sequence_keys = Pointer(Void).null
    @key_tables = [] of {String, Bool}

    # Returns the names of the active key tables, the innermost last.
    def key_tables : Array(String)
      @key_tables.map(&.[0])
    end

    # Pushes the key table *name*, popped after its first binding when
    # *once*. False for an unknown table, the innermost one, or a full
    # stack.
    protected def activate_key_table(name : String, once : Bool) : Bool
      return false unless @app.key_table?(name)
      return false if @key_tables.last?.try(&.[0]) == name
      if @key_tables.size >= KEY_TABLE_LIMIT
        Log.warn { "key table #{name}: #{KEY_TABLE_LIMIT} tables are active already" }
        return false
      end
      @key_tables << {name, once}
      sync_key_state
      true
    end

    protected def deactivate_key_table : Bool
      return false unless @key_tables.pop?
      sync_key_state
      true
    end

    protected def deactivate_all_key_tables : Bool
      return false if @key_tables.empty?
      @key_tables.clear
      sync_key_state
      true
    end

    # Follows the key sequences: a key that starts or continues one is
    # taken, one that completes it performs its action, and any other key
    # while one is pending ends it and is dropped.
    private def sequence_key(keyval : UInt32, state : UInt32) : Bool
      return false if @sequence.empty? && @key_tables.empty? && !@app.sequences?
      event = C.gtk_event_controller_get_current_event(@sequence_keys)
      return false if !event.null? && C.gdk_key_event_is_modifier(event) != 0
      mods = Mods.from_gdk(C::GdkModifierType.new(state))
      consumed = event.null? ? Mods::None : Mods.from_gdk(C.gdk_key_event_get_consumed_modifiers(event))
      {mods, mods & ~consumed}.each do |held|
        trigger = Trigger.new?(keyval, held) || next
        keys = @sequence + [trigger]
        case match = @app.key_match(@key_tables, keys)
        when Tuple
          action, table = match
          end_sequence
          @key_tables.pop if table && @key_tables.last? == {table, true}
          sync_key_state
          Log.warn { "binding #{keys.join('>')}: action #{action.detailed_name} not handled" } unless @app.perform_in(self, action)
          return true
        when true
          @sequence = keys
          restart_sequence_timer
          sync_key_state
          return true
        end
      end
      return false if @sequence.empty?
      end_sequence
      sync_key_state
      true
    end

    # Drops the pending sequence after `App#sequence_timeout`, counted from
    # its latest key.
    private def restart_sequence_timer : Nil
      stop_sequence_timer
      timeout = @app.sequence_timeout || return
      @sequence_timer = Idle.after(timeout) do
        @sequence_timer = 0_u32
        @sequence.clear
        sync_key_state
      end
    end

    private def end_sequence : Nil
      stop_sequence_timer
      @sequence.clear
    end

    private def stop_sequence_timer : Nil
      Idle.cancel(@sequence_timer) unless @sequence_timer == 0
      @sequence_timer = 0_u32
    end

    # Shows the active key tables and the pending sequence in the corner
    # overlay, or hides it when there are none.
    private def sync_key_state : Nil
      parts = key_tables
      parts << @sequence.join(' ', &.label) unless @sequence.empty?
      C.gtk_label_set_label(@key_state, parts.join(" › "))
      @key_state.visible = !parts.empty?
    end
  end
end
