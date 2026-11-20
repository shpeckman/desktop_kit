# src/apprt/ui/menu.cr
module Apprt
  # A menu of actions in sections, with submenus: the window menu
  # (`App#window_menu=`) and context menus (`Content#context_menu`).
  #
  # ```
  # menu = Apprt::Menu.build do |items|
  #   items.item "New Tab", Apprt::Action::NewTab.new
  #   items.section
  #   items.submenu "Split" do |split|
  #     split.item "Right", Apprt::Action::NewSplit.new(:right)
  #     split.item "Down", Apprt::Action::NewSplit.new(:down)
  #   end
  # end
  # ```
  class Menu
    # An entry: a *label* and the action it performs or the submenu it opens.
    record Item, label : String, target : Action | Menu

    # Returns the sections, each a list of items; separators show between
    # sections.
    getter sections : Array(Array(Item))

    # Creates a menu of *sections*.
    def initialize(@sections : Array(Array(Item)) = [[] of Item])
    end

    # Returns a menu that the block fills.
    def self.build(& : Menu ->) : Menu
      menu = new
      yield menu
      menu
    end

    # Returns the window menu apprt shows by default.
    def self.window : Menu
      build do |menu|
        menu.item "New Window", Action::NewWindow.new
        menu.item "New Tab", Action::NewTab.new
        menu.section
        menu.item "Split Up", Action::NewSplit.new(:up)
        menu.item "Split Down", Action::NewSplit.new(:down)
        menu.item "Split Left", Action::NewSplit.new(:left)
        menu.item "Split Right", Action::NewSplit.new(:right)
        menu.section
        menu.item "Change Title…", Action::PromptTitle.new(:surface)
        menu.item "Change Tab Title…", Action::PromptTitle.new(:tab)
        menu.item "Change Window Title…", Action::PromptTitle.new(:window)
        menu.section
        menu.item "Close Tab", Action::CloseTab.new(:this)
        menu.item "Close Window", Action::CloseWindow.new
      end
    end

    # Appends an item with *label* that performs *action* to the last
    # section.
    def item(label : String, action : Action) : self
      @sections.last << Item.new(label, action)
      self
    end

    # Appends an item with *label* that opens the submenu the block fills.
    def submenu(label : String, & : Menu ->) : self
      @sections.last << Item.new(label, Menu.build { |menu| yield menu })
      self
    end

    # Starts a new section; later items show below a separator.
    def section : self
      @sections << [] of Item unless @sections.last.empty?
      self
    end

    # Returns whether the menu has no items.
    def empty? : Bool
      @sections.all?(&.empty?)
    end

    # Returns a new `GMenu` of the menu; the caller owns it.
    protected def to_model : Void*
      model = C.g_menu_new
      @sections.each do |items|
        next if items.empty?
        section = C.g_menu_new
        items.each do |item|
          case target = item.target
          in Action
            C.g_menu_append(section, item.label, target.detailed_name)
          in Menu
            submenu = target.to_model
            C.g_menu_append_submenu(section, item.label, submenu)
            C.g_object_unref(submenu)
          end
        end
        C.g_menu_append_section(model, nil, section)
        C.g_object_unref(section)
      end
      model
    end
  end
end
