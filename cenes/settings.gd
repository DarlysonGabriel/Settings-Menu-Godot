extends CanvasLayer

static var instance = null

# Configuration

@export_group("Open / Close")
@export var start_closed: bool = true
@export var toggle_key: Key = KEY_ESCAPE
@export var open_button: Button

@export_group("Visual")
@export_range(260.0, 1200.0, 1.0) var panel_width: float = 320.0
@export_range(0.50, 1.00, 0.01) var content_width_scale: float = 0.94
@export_range(0.0, 40.0, 1.0) var scrollbar_padding: float = 8.0
@export_range(0.50, 1.50, 0.01) var ui_scale: float = 1.0
@export var panel_color: Color = Color(0.12, 0.11, 0.16, 0.96)

# Kept exposed for project-level theming. The current runtime UI does not use
# these two values yet, so changing them has no visible effect at the moment.

@export var sidebar_color: Color = Color(0.08, 0.075, 0.11, 1.0)
@export var accent_color: Color = Color(0.48, 0.28, 1.0, 1.0)
@export var animation_time: float = 0.22

@export_group("Controls")
@export var action_names: Array[String] = [
	"p0_button_0",
	"p0_button_1",
	"p0_button_2",
	"p0_button_3"
]

@export var action_labels: Array[String] = [
	"Track 1",
	"Track 2",
	"Track 3",
	"Track 4"
]

@export var default_keys: Array[Key] = [
	KEY_A,
	KEY_S,
	KEY_D,
	KEY_W,
	KEY_SHIFT,
	KEY_SPACE
]

@export_group("Audio")
@export var master_bus_name: String = "Master"
@export var music_bus_name: String = "Music"
@export var sfx_bus_name: String = "SFX"

@export_range(0.0, 100.0)
var default_master_volume: float = 100.0

@export_range(0.0, 100.0)
var default_music_volume: float = 80.0

@export_range(0.0, 100.0)
var default_sfx_volume: float = 80.0

# Runtime state

const SAVE_PATH: String = "user://settings.cfg"

# Supported values are kept in one place so the UI, validation, and save/load
# logic cannot silently drift apart when a new option is added.

const FPS_LIMITS: Array[int] = [30, 60, 120, 144, 240, 0]
const MSAA_SAMPLE_COUNTS: Array[int] = [0, 2, 4, 8]


var root_panel: Panel
var sidebar: VBoxContainer
var content: VBoxContainer
var scroll_container: ScrollContainer

var master_slider: HSlider
var music_slider: HSlider
var sfx_slider: HSlider


var waiting_action: String = ""

var key_buttons: Dictionary = {}
var gamepad_buttons: Dictionary = {}
var waiting_input_type: String = ""

var opened: bool = false
var tween: Tween = null


# Graphics settings
# These values are exposed in the Inspector and act as the default game settings.

@export_group("Graphics Defaults")
@export_enum("Disabled:0", "Enabled:1", "Adaptive:2")
var default_vsync_mode: int = 1

# 0 = Windowed, 1 = Borderless Windowed, 2 = Exclusive Fullscreen, 3 = Borderless Fullscreen.

@export_enum("Windowed:0", "Borderless Windowed:1", "Fullscreen:2", "Borderless Fullscreen:3")
var default_window_mode: int = 0

@export_enum("Disabled:0", "2x MSAA:1", "4x MSAA:2", "8x MSAA:3")
var default_msaa_2d: int = 0

@export var default_texture_filter_nearest: bool = false

# Show or hide the Pixel Snap option in the settings menu.

@export var show_pixel_snap_option: bool = true

# Default Pixel Snap state used when the player restores graphics settings.

@export var default_pixel_snap_enabled: bool = false

@export_enum("30 FPS:30", "60 FPS:60", "120 FPS:120", "144 FPS:144", "240 FPS:240", "Unlimited:0")
var default_fps_limit: int = 60

var vsync_mode: int = 1
var window_mode: int = 0
var pending_window_mode: int = 0
var msaa_2d: int = 0
var texture_filter_nearest: bool = false
var pixel_snap_enabled: bool = false
var fps_limit: int = 60


## Initializes the settings manager and builds its entire UI at runtime.
## The order matters: defaults and saved values must be loaded before the
## visible page is rebuilt, otherwise the controls can display stale values.

func _ready() -> void:
	instance = self
	layer = 999

	create_default_input_actions()
	set_graphics_to_inspector_defaults()
	build_ui()
	load_settings()
	# Rebuild the visible page so the controls reflect saved values.

	show_general_page()
	apply_audio_settings()

	# Keep the panel fitted when the game window or viewport changes size.

	get_viewport().size_changed.connect(_update_panel_layout)

	if open_button != null:
		open_button.pressed.connect(open_settings)

	if start_closed:
		close_settings_instant()
	else:
		open_settings_instant()


## Handles both the settings toggle shortcut and interactive input remapping.
## While a remap is active, the next valid keyboard key, gamepad button, or
## sufficiently strong analog-axis movement is consumed by the remapping code.

func _input(event: InputEvent) -> void:
	# Keyboard binding remapping
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey

		if key_event.pressed and !key_event.echo:
			if waiting_action != "" and waiting_input_type == "keyboard":
				remap_keyboard_action(waiting_action, key_event.keycode)
				_finish_remap()
				get_viewport().set_input_as_handled()
				return

			if key_event.keycode == toggle_key:
				toggle_settings()
				get_viewport().set_input_as_handled()
				return

	# Gamepad binding button remapping

	if event is InputEventJoypadButton:
		var joy_button: InputEventJoypadButton = event as InputEventJoypadButton

		if joy_button.pressed and waiting_action != "" and waiting_input_type == "gamepad":
			remap_gamepad_button(waiting_action, joy_button.button_index)
			_finish_remap()
			get_viewport().set_input_as_handled()
			return

	# Gamepad binding axis remapping

	if event is InputEventJoypadMotion:
		var joy_motion: InputEventJoypadMotion = event as InputEventJoypadMotion

		if waiting_action != "" and waiting_input_type == "gamepad":
			if abs(joy_motion.axis_value) >= 0.7:
				remap_gamepad_axis(
					waiting_action,
					joy_motion.axis,
					joy_motion.axis_value
				)
				_finish_remap()
				get_viewport().set_input_as_handled()
				return


func _finish_remap() -> void:
	waiting_action = ""
	waiting_input_type = ""


# UI

## Creates the complete settings layout from code.
## No scene hierarchy is required for the menu itself: this CanvasLayer builds
## the panel, sidebar, scroll area, and page container during runtime.

func build_ui() -> void:
	root_panel = Panel.new()
	add_child(root_panel)

	root_panel.anchor_left = 0.0
	root_panel.anchor_top = 0.0
	root_panel.anchor_right = 0.0
	root_panel.anchor_bottom = 0.0

	root_panel.offset_left = 0.0
	root_panel.offset_top = 0.0
	root_panel.offset_right = panel_width

	# The panel uses a reduced base height so its scaled size stays
	# within the viewport height instead of extending beyond the screen.

	_update_panel_layout()

	var style: StyleBoxFlat = StyleBoxFlat.new()

	style.bg_color = panel_color
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_right = 4

	root_panel.add_theme_stylebox_override("panel", style)

	var margin: MarginContainer = MarginContainer.new()

	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0

	margin.add_theme_constant_override("margin_left", 3)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_right", 3)
	margin.add_theme_constant_override("margin_bottom", 3)

	root_panel.add_child(margin)

	var main: HBoxContainer = HBoxContainer.new()

	main.add_theme_constant_override("separation", 6)

	margin.add_child(main)

	sidebar = VBoxContainer.new()

	sidebar.custom_minimum_size.x = 80.0
	sidebar.add_theme_constant_override("separation", 3)

	main.add_child(sidebar)

	scroll_container = ScrollContainer.new()

	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	main.add_child(scroll_container)

	# Reserve space for the scrollbar so the content keeps a predictable width.
	# This prevents the content from visually reaching the edge of the ScrollContainer viewport.

	var content_margin: MarginContainer = MarginContainer.new()
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_margin.add_theme_constant_override("margin_left", 0)
	content_margin.add_theme_constant_override("margin_top", 0)
	content_margin.add_theme_constant_override("margin_right", int(scrollbar_padding))
	content_margin.add_theme_constant_override("margin_bottom", 0)
	scroll_container.add_child(content_margin)

	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.custom_minimum_size.x = (68.0 + 72.0 + 72.0 + 8.0) * content_width_scale
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 3)
	content_margin.add_child(content)

	build_sidebar()
	show_general_page()


## Updates the panel's base height according to the current viewport and UI scale.
## Scaling a full-height Control directly makes it exceed the screen when ui_scale
## is greater than 1.0. Reducing its unscaled height first keeps the final scaled
## height within the CanvasLayer's visible area.

func _update_panel_layout() -> void:
	if root_panel == null:
		return

	var viewport_height: float = get_viewport().get_visible_rect().size.y
	var safe_scale: float = maxf(ui_scale, 0.01)

	root_panel.scale = Vector2(safe_scale, safe_scale)
	root_panel.offset_bottom = viewport_height / safe_scale


func build_sidebar() -> void:
	clear_container(sidebar)

	var title: Label = Label.new()

	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 11)
	title.custom_minimum_size.y = 20
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	sidebar.add_child(title)

	create_sidebar_button("General", show_general_page)
	create_sidebar_button("Controls", show_controls_page)
	create_sidebar_button("Audio", show_audio_page)

	var spacer: Control = Control.new()

	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	sidebar.add_child(spacer)

	var close_btn: Button = Button.new()

	close_btn.text = "Close"
	close_btn.custom_minimum_size.y = 20
	close_btn.add_theme_font_size_override("font_size", 10)

	close_btn.pressed.connect(close_settings)

	sidebar.add_child(close_btn)


func create_sidebar_button(text: String, callback: Callable) -> void:
	var btn: Button = Button.new()

	btn.text = text
	btn.custom_minimum_size.y = 20
	btn.add_theme_font_size_override("font_size", 10)

	btn.pressed.connect(callback)

	sidebar.add_child(btn)


# GENERAL
# ============================================================

## Rebuilds the General page and synchronizes each OptionButton with the
## current runtime value.
## Rebuilding the page keeps the code simple and avoids maintaining references
## to every option control when the menu changes between pages.

func show_general_page() -> void:
	clear_container(content)

	content.add_child(create_title("General"))

	# --------------------------------------------------------
	# GRAPHICS
	# --------------------------------------------------------

	content.add_child(create_subtitle("Graphics"))
	content.add_child(create_separator())

	# V-Sync
	var vsync_row: HBoxContainer = create_option_row(
		"V-Sync",
		["Disabled", "Enabled", "Adaptive"]
	)
	var vsync_button: OptionButton = vsync_row.get_node("OptionButton")
	vsync_button.select(get_vsync_index())
	vsync_button.item_selected.connect(_on_vsync_selected)
	content.add_child(vsync_row)

	# Window Mode
	var window_mode_row: HBoxContainer = create_option_row(
		"Window Mode",
		[
			"Windowed",
			"Borderless",
			"Fullscreen",
			"Borderless FS"
		]
	)
	var window_mode_button: OptionButton = window_mode_row.get_node("OptionButton")
	window_mode_button.select(get_window_mode_index())
	window_mode_button.item_selected.connect(_on_window_mode_selected)
	window_mode_button.fit_to_longest_item = false
	content.add_child(window_mode_row)

	# Anti-Aliasing
	var aa_row: HBoxContainer = create_option_row(
		"Anti-Aliasing",
		["Disabled", "2x MSAA", "4x MSAA", "8x MSAA"]
	)
	var aa_button: OptionButton = aa_row.get_node("OptionButton")
	aa_button.select(get_msaa_index())
	aa_button.item_selected.connect(_on_msaa_selected)
	content.add_child(aa_row)

	# Texture Filtering
	var filter_row: HBoxContainer = create_option_row(
		"Texture Filtering",
		["Nearest", "Linear"]
	)
	var filter_button: OptionButton = filter_row.get_node("OptionButton")
	filter_button.select(get_filtering_index())
	filter_button.item_selected.connect(_on_filtering_selected)
	content.add_child(filter_row)

	# Pixel Snap (opcional)
	if show_pixel_snap_option:
		var pixel_row: HBoxContainer = create_option_row(
			"Pixel Snap",
			["Disabled", "Enabled"]
		)
		var pixel_button: OptionButton = pixel_row.get_node("OptionButton")
		pixel_button.select(get_pixel_snap_index())
		pixel_button.item_selected.connect(_on_pixel_snap_selected)
		content.add_child(pixel_row)

	# FPS Limit

	var fps_row: HBoxContainer = create_option_row(
		"FPS Limit",
		["30 FPS", "60 FPS", "120 FPS", "144 FPS", "240 FPS", "Unlimited"]
	)
	var fps_button: OptionButton = fps_row.get_node("OptionButton")
	fps_button.select(get_fps_index())
	fps_button.item_selected.connect(_on_fps_selected)
	content.add_child(fps_row)

	# --------------------------------------------------------
	# RESET / APPLY
	# --------------------------------------------------------

	var reset_graphics_btn: Button = Button.new()
	reset_graphics_btn.text = "Reset Graphics Default"
	reset_graphics_btn.custom_minimum_size.y = 20
	reset_graphics_btn.add_theme_font_size_override("font_size", 10)
	reset_graphics_btn.pressed.connect(reset_graphics_to_default)
	content.add_child(reset_graphics_btn)

	var apply_btn: Button = Button.new()
	apply_btn.text = "Apply Changes"
	apply_btn.custom_minimum_size.y = 20
	apply_btn.add_theme_font_size_override("font_size", 10)
	apply_btn.pressed.connect(apply_graphics_changes)
	content.add_child(apply_btn)


## Creates a reusable label + OptionButton row used by the General page.
## The OptionButton is named so the caller can retrieve it from the returned row
## without storing another dedicated member variable for every setting.

func create_option_row(label_text: String, options: Array[String]) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var label: Label = Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 10)
	label.custom_minimum_size.x = 90
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var button: OptionButton = OptionButton.new()
	button.name = "OptionButton"
	button.custom_minimum_size.x = 100
	button.custom_minimum_size.y = 18
	button.add_theme_font_size_override("font_size", 9)

	for i in options.size():
		button.add_item(options[i], i)

	row.add_child(button)

	return row


# ============================================================
# GRAPHICS
# ============================================================

func set_graphics_to_inspector_defaults() -> void:
	vsync_mode = clampi(default_vsync_mode, 0, 2)
	window_mode = clampi(default_window_mode, 0, 3)
	msaa_2d = clampi(default_msaa_2d, 0, 3)
	texture_filter_nearest = default_texture_filter_nearest
	pixel_snap_enabled = default_pixel_snap_enabled
	fps_limit = default_fps_limit
	pending_window_mode = window_mode

	if !FPS_LIMITS.has(fps_limit):
		fps_limit = 60


func reset_graphics_to_default() -> void:
	set_graphics_to_inspector_defaults()
	pending_window_mode = window_mode
	apply_graphics_settings()
	save_settings()

	# Rebuild the page so the Inspector defaults are reflected immediately.

	show_general_page()


func get_vsync_index() -> int:
	return clampi(vsync_mode, 0, 2)


func _on_vsync_selected(index: int) -> void:
	vsync_mode = clampi(index, 0, 2)
	apply_vsync()
	save_settings()


func get_window_mode_index() -> int:
	pending_window_mode = clampi(pending_window_mode, 0, 3)
	return pending_window_mode


func _on_window_mode_selected(index: int) -> void:
	pending_window_mode = clampi(index, 0, 3)


func get_msaa_index() -> int:
	return clampi(msaa_2d, 0, 3)


func _on_msaa_selected(index: int) -> void:
	msaa_2d = clampi(index, 0, 3)
	apply_msaa()
	save_settings()


func get_filtering_index() -> int:
	return 0 if texture_filter_nearest else 1


func _on_filtering_selected(index: int) -> void:
	texture_filter_nearest = index == 0
	apply_texture_filtering()
	save_settings()


func get_pixel_snap_index() -> int:
	return 1 if pixel_snap_enabled else 0


func _on_pixel_snap_selected(index: int) -> void:
	pixel_snap_enabled = index == 1
	apply_pixel_snap()
	save_settings()


func get_fps_index() -> int:
	match fps_limit:
		30:
			return 0
		60:
			return 1
		120:
			return 2
		144:
			return 3
		240:
			return 4
		_:
			return 5


func _on_fps_selected(index: int) -> void:
	fps_limit = FPS_LIMITS[clampi(index, 0, FPS_LIMITS.size() - 1)]
	Engine.max_fps = fps_limit
	save_settings()


# ============================================================
# APPLY GRAPHICS
# ============================================================

func apply_graphics_changes() -> void:
	# Window Mode is only applied when the player confirms the changes.

	window_mode = clampi(pending_window_mode, 0, 3)
	apply_window_mode()
	save_settings()


## Applies every graphics setting to the current runtime.
## This method is used during startup after loading the saved configuration and
## is also useful when another system needs to re-apply all graphics at once.

func apply_graphics_settings() -> void:
	apply_vsync()
	apply_window_mode()
	apply_msaa()
	apply_pixel_snap()
	Engine.max_fps = fps_limit
	apply_texture_filtering()


func apply_vsync() -> void:
	match vsync_mode:
		0:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		1:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		2:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ADAPTIVE)


## Converts the menu window-mode index into the corresponding DisplayServer mode.
## Borderless state is configured explicitly for each case so switching between
## fullscreen and windowed modes does not depend on a previous window state.

func apply_window_mode() -> void:
	var mode: int = clampi(window_mode, 0, 3)

	match mode:
		0:
			# Standard windowed mode.

			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_BORDERLESS,
				false
			)

		1:
			# Borderless windowed mode.

			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_BORDERLESS,
				true
			)

		2:
			# Exclusive fullscreen mode.

			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_BORDERLESS,
				false
			)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)

		3:
			# Borderless fullscreen mode.
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_BORDERLESS,
				false
			)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


## Applies the selected 2D anti-aliasing mode to the current viewport.
## Compatibility rendering uses FXAA here, while renderers that expose 2D MSAA
## receive the selected sample count. This keeps one settings option portable
## across the supported renderers.

func apply_msaa() -> void:
	var viewport: Viewport = get_viewport()
	var value: int = clampi(msaa_2d, 0, 3)

	# In Compatibility mode, use FXAA instead of viewport MSAA.
	# This keeps the anti-aliasing option functional in this renderer.

	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		viewport.screen_space_aa = (
			Viewport.SCREEN_SPACE_AA_DISABLED
			if value == 0
			else Viewport.SCREEN_SPACE_AA_FXAA
		)
		viewport.msaa_2d = Viewport.MSAA_DISABLED
		return

	match value:
		0:
			viewport.msaa_2d = Viewport.MSAA_DISABLED
		1:
			viewport.msaa_2d = Viewport.MSAA_2X
		2:
			viewport.msaa_2d = Viewport.MSAA_4X
		3:
			viewport.msaa_2d = Viewport.MSAA_8X

	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED


func apply_pixel_snap() -> void:
	RenderingServer.viewport_set_snap_2d_transforms_to_pixel(
		get_viewport().get_viewport_rid(),
		pixel_snap_enabled
	)


func apply_texture_filtering() -> void:
	_apply_texture_filter_to_node(get_tree().root)


## Recursively applies the selected texture filter to every CanvasItem.
## The recursion is intentional: the menu is a project-level setting, so newly
## discovered CanvasItem descendants are updated without requiring manual node
## references throughout the project.

func _apply_texture_filter_to_node(node: Node) -> void:
	if node is CanvasItem:
		var item: CanvasItem = node as CanvasItem
		if texture_filter_nearest:
			item.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		else:
			item.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	for child in node.get_children():
		_apply_texture_filter_to_node(child)



# CONTROLS
# ============================================================

## Rebuilds the Controls page from the actions declared in the Inspector.
## Each row is generated from the same action name, which keeps keyboard and
## gamepad displays aligned with InputMap instead of duplicating configuration.

func show_controls_page() -> void:
	clear_container(content)
	key_buttons.clear()
	gamepad_buttons.clear()

	content.add_child(create_title("Controls"))
	content.add_child(create_subtitle("Keyboard / Gamepad"))

	var default_btn: Button = Button.new()
	default_btn.text = "Reset Default"
	default_btn.custom_minimum_size.y = 18
	default_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	default_btn.add_theme_font_size_override("font_size", 9)
	default_btn.pressed.connect(reset_controls_to_default)
	content.add_child(default_btn)

	content.add_child(create_separator())

	# Keep a fixed three-column grid so headers and rows stay aligned.
	
	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.custom_minimum_size.x = 0.0
	grid.add_theme_constant_override("h_separation", int(4.0 * content_width_scale))
	grid.add_theme_constant_override("v_separation", 3)
	content.add_child(grid)

	var header_action: Label = Label.new()
	header_action.text = "Action"
	header_action.custom_minimum_size.x = 68.0 * content_width_scale
	header_action.add_theme_font_size_override("font_size", 9)
	grid.add_child(header_action)

	var header_keyboard: Label = Label.new()
	header_keyboard.text = "Keyboard"
	header_keyboard.custom_minimum_size.x = 72.0 * content_width_scale
	header_keyboard.add_theme_font_size_override("font_size", 9)
	grid.add_child(header_keyboard)

	var header_gamepad: Label = Label.new()
	header_gamepad.text = "Gamepad"
	header_gamepad.custom_minimum_size.x = 72.0 * content_width_scale
	header_gamepad.add_theme_font_size_override("font_size", 9)
	grid.add_child(header_gamepad)

	for i in action_names.size():
		var action: String = action_names[i]

		var label_text: String = (
			action_labels[i]
			if i < action_labels.size()
			else action
		)

		var label: Label = Label.new()
		label.text = label_text
		label.custom_minimum_size.x = 68.0 * content_width_scale
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 9)
		grid.add_child(label)

		# Keyboard binding

		var key_button: Button = Button.new()
		key_button.text = get_action_key_text(action)
		key_button.custom_minimum_size.x = 72.0 * content_width_scale
		key_button.custom_minimum_size.y = 18
		key_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key_button.add_theme_font_size_override("font_size", 9)
		key_button.pressed.connect(
			func():
				start_keyboard_remap(action, key_button)
		)
		grid.add_child(key_button)
		key_buttons[action] = key_button

		# Gamepad binding

		var pad_button: Button = Button.new()
		pad_button.text = get_action_gamepad_text(action)
		pad_button.custom_minimum_size.x = 72.0 * content_width_scale
		pad_button.custom_minimum_size.y = 18
		pad_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad_button.add_theme_font_size_override("font_size", 9)
		pad_button.pressed.connect(
			func():
				start_gamepad_remap(action, pad_button)
		)
		grid.add_child(pad_button)
		gamepad_buttons[action] = pad_button

	var apply_btn: Button = Button.new()
	apply_btn.text = "Apply"
	apply_btn.custom_minimum_size.y = 20
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_btn.add_theme_font_size_override("font_size", 10)
	apply_btn.pressed.connect(save_settings)
	content.add_child(apply_btn)


# ============================================================
# AUDIO
# ============================================================

## Rebuilds the Audio page and creates one slider for each configured audio bus.
## Sliders are initialized from the Inspector defaults, then overwritten with
## persisted values when a settings file exists.

func show_audio_page() -> void:
	clear_container(content)

	content.add_child(create_title("Audio"))
	content.add_child(create_subtitle("Adjust volumes"))

	var default_btn: Button = Button.new()

	default_btn.text = "Reset Default"
	default_btn.custom_minimum_size.y = 18

	default_btn.add_theme_font_size_override("font_size", 9)

	default_btn.pressed.connect(reset_audio_to_default)

	content.add_child(default_btn)

	content.add_child(create_separator())

	master_slider = create_volume_slider(
		"Master",
		default_master_volume
	)

	music_slider = create_volume_slider(
		"Music",
		default_music_volume
	)

	sfx_slider = create_volume_slider(
		"SFX",
		default_sfx_volume
	)

	content.add_child(master_slider.get_parent())
	content.add_child(music_slider.get_parent())
	content.add_child(sfx_slider.get_parent())

	load_settings_to_sliders()

	var apply_btn: Button = Button.new()

	apply_btn.text = "Apply"
	apply_btn.custom_minimum_size.y = 20

	apply_btn.add_theme_font_size_override("font_size", 10)

	apply_btn.pressed.connect(apply_and_save_audio)

	content.add_child(apply_btn)


## Builds a labeled volume slider and returns the slider itself.
## The slider is placed inside its own VBoxContainer so the label and control
## remain visually grouped while the caller can still access the value directly.

func create_volume_slider(
	label_text: String,
	default_value: float
) -> HSlider:

	var box: VBoxContainer = VBoxContainer.new()

	box.add_theme_constant_override("separation", 1)

	var label: Label = Label.new()

	label.text = label_text
	label.add_theme_font_size_override("font_size", 9)

	box.add_child(label)

	var slider: HSlider = HSlider.new()

	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = default_value

	slider.custom_minimum_size.y = 14

	box.add_child(slider)

	return slider


func apply_and_save_audio() -> void:
	apply_bus_volume(
		master_bus_name,
		master_slider.value
	)

	apply_bus_volume(
		music_bus_name,
		music_slider.value
	)

	apply_bus_volume(
		sfx_bus_name,
		sfx_slider.value
	)

	save_settings()


## Reads saved audio values and applies them directly to the configured buses.
## The sliders are not required here, which allows audio settings to be restored
## during startup before the Audio page has been opened.

func apply_audio_settings() -> void:
	var config: ConfigFile = ConfigFile.new()

	var err: Error = config.load(SAVE_PATH)

	var master_value: float = default_master_volume
	var music_value: float = default_music_volume
	var sfx_value: float = default_sfx_volume

	if err == OK:

		master_value = float(
			config.get_value(
				"audio",
				"master",
				default_master_volume
			)
		)

		music_value = float(
			config.get_value(
				"audio",
				"music",
				default_music_volume
			)
		)

		sfx_value = float(
			config.get_value(
				"audio",
				"sfx",
				default_sfx_volume
			)
		)

	apply_bus_volume(
		master_bus_name,
		master_value
	)

	apply_bus_volume(
		music_bus_name,
		music_value
	)

	apply_bus_volume(
		sfx_bus_name,
		sfx_value
	)


func apply_bus_volume(
	bus_name: String,
	value: float
) -> void:

	var bus_index: int = AudioServer.get_bus_index(bus_name)

	if bus_index == -1:
		return

	var linear: float = clampf(
		value / 100.0,
		0.0,
		1.0
	)

	if linear <= 0.0:

		AudioServer.set_bus_mute(
			bus_index,
			true
		)

		AudioServer.set_bus_volume_db(
			bus_index,
			-80.0
		)

	else:

		AudioServer.set_bus_mute(
			bus_index,
			false
		)

		AudioServer.set_bus_volume_db(
			bus_index,
			linear_to_db(linear)
		)


func load_settings_to_sliders() -> void:
	var config: ConfigFile = ConfigFile.new()

	if config.load(SAVE_PATH) != OK:
		return

	if master_slider:
		master_slider.value = float(
			config.get_value(
				"audio",
				"master",
				default_master_volume
			)
		)

	if music_slider:
		music_slider.value = float(
			config.get_value(
				"audio",
				"music",
				default_music_volume
			)
		)

	if sfx_slider:
		sfx_slider.value = float(
			config.get_value(
				"audio",
				"sfx",
				default_sfx_volume
			)
		)


func reset_audio_to_default() -> void:

	if master_slider:
		master_slider.value = default_master_volume

	if music_slider:
		music_slider.value = default_music_volume

	if sfx_slider:
		sfx_slider.value = default_sfx_volume

	apply_and_save_audio()


# ============================================================
# INPUT
# ============================================================

## Ensures every configured action exists and receives a default key when empty.
## Existing InputMap bindings are preserved, so project-defined bindings are not
## overwritten merely because the settings manager starts.

func create_default_input_actions() -> void:
	for i in action_names.size():
		var action: String = action_names[i]

		if !InputMap.has_action(action):
			InputMap.add_action(action)

		if InputMap.action_get_events(action).is_empty() and i < default_keys.size():
			var ev: InputEventKey = InputEventKey.new()
			ev.keycode = default_keys[i]
			InputMap.action_add_event(action, ev)


## Marks an action as waiting for the next keyboard key and updates the button
## so the player knows that input capture is active.
func start_keyboard_remap(action: String, button: Button) -> void:
	waiting_action = action
	waiting_input_type = "keyboard"
	button.text = "Press key..."


## Marks an action as waiting for the next gamepad button or axis movement.
## Axis input uses a threshold in _input() so small joystick noise is ignored.

func start_gamepad_remap(action: String, button: Button) -> void:
	waiting_action = action
	waiting_input_type = "gamepad"
	button.text = "Press button..."


## Removes all keyboard, gamepad-button, and gamepad-axis bindings managed by
## this settings script for the given action.

func clear_action_bindings(action: String) -> void:
	if !InputMap.has_action(action):
		return

	for event in InputMap.action_get_events(action):
		if (
			event is InputEventKey
			or event is InputEventJoypadButton
			or event is InputEventJoypadMotion
		):
			InputMap.action_erase_event(action, event)


func remap_keyboard_action(action: String, keycode: Key) -> void:
	if !InputMap.has_action(action):
		return

	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			InputMap.action_erase_event(action, event)

	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = keycode
	InputMap.action_add_event(action, ev)

	if key_buttons.has(action) and key_buttons[action] != null:
		key_buttons[action].text = OS.get_keycode_string(keycode)

	save_settings()


func remap_gamepad_button(action: String, button_index: JoyButton) -> void:
	if !InputMap.has_action(action):
		return

	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton:
			InputMap.action_erase_event(action, event)

	var ev: InputEventJoypadButton = InputEventJoypadButton.new()
	ev.button_index = button_index
	ev.device = -1
	InputMap.action_add_event(action, ev)

	if gamepad_buttons.has(action) and gamepad_buttons[action] != null:
		gamepad_buttons[action].text = get_joy_button_name(button_index)

	save_settings()


func remap_gamepad_axis(
	action: String,
	axis: JoyAxis,
	axis_value: float
) -> void:
	if !InputMap.has_action(action):
		return

	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadMotion:
			InputMap.action_erase_event(action, event)

	var ev: InputEventJoypadMotion = InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = 1.0 if axis_value > 0.0 else -1.0
	ev.device = -1
	InputMap.action_add_event(action, ev)

	if gamepad_buttons.has(action) and gamepad_buttons[action] != null:
		gamepad_buttons[action].text = get_joy_axis_name(axis, axis_value)

	save_settings()


## Restores the configured keyboard defaults and removes custom gamepad
## bindings for the managed actions.
## Gamepad bindings are cleared rather than replaced with a fixed preset because
## different games can expose different controller layouts.

func reset_controls_to_default() -> void:
	for i in action_names.size():
		if i < default_keys.size():
			remap_keyboard_action(
				action_names[i],
				default_keys[i]
			)

			# Remove all gamepad bindings when restoring defaults.
			var action: String = action_names[i]

			if InputMap.has_action(action):
				for event in InputMap.action_get_events(action):
					if event is InputEventJoypadButton or event is InputEventJoypadMotion:
						InputMap.action_erase_event(action, event)

			if gamepad_buttons.has(action) and gamepad_buttons[action] != null:
				gamepad_buttons[action].text = "None"

	save_settings()


func get_action_key_text(action: String) -> String:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return OS.get_keycode_string(
				(event as InputEventKey).keycode
			)

	return "None"


func get_action_gamepad_text(action: String) -> String:
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton:
			return get_joy_button_name(
				(event as InputEventJoypadButton).button_index
			)

		if event is InputEventJoypadMotion:
			var motion: InputEventJoypadMotion = event as InputEventJoypadMotion
			return get_joy_axis_name(
				motion.axis,
				motion.axis_value
			)

	return "None"


func get_joy_button_name(button: JoyButton) -> String:
	match button:
		JOY_BUTTON_A:
			return "A"
		JOY_BUTTON_B:
			return "B"
		JOY_BUTTON_X:
			return "X"
		JOY_BUTTON_Y:
			return "Y"
		JOY_BUTTON_BACK:
			return "Back"
		JOY_BUTTON_GUIDE:
			return "Guide"
		JOY_BUTTON_START:
			return "Start"
		JOY_BUTTON_LEFT_STICK:
			return "L3"
		JOY_BUTTON_RIGHT_STICK:
			return "R3"
		JOY_BUTTON_LEFT_SHOULDER:
			return "LB"
		JOY_BUTTON_RIGHT_SHOULDER:
			return "RB"
		JOY_BUTTON_DPAD_UP:
			return "D-Up"
		JOY_BUTTON_DPAD_DOWN:
			return "D-Down"
		JOY_BUTTON_DPAD_LEFT:
			return "D-Left"
		JOY_BUTTON_DPAD_RIGHT:
			return "D-Right"
		_:
			return "Button " + str(int(button))


func get_joy_axis_name(axis: JoyAxis, value: float) -> String:
	var direction := "+" if value > 0.0 else "-"

	match axis:
		JOY_AXIS_LEFT_X:
			return "Left X" + direction
		JOY_AXIS_LEFT_Y:
			return "Left Y" + direction
		JOY_AXIS_RIGHT_X:
			return "Right X" + direction
		JOY_AXIS_RIGHT_Y:
			return "Right Y" + direction
		JOY_AXIS_TRIGGER_LEFT:
			return "LT"
		JOY_AXIS_TRIGGER_RIGHT:
			return "RT"
		_:
			return "Axis " + str(int(axis)) + direction


# ============================================================
# SAVE / LOAD
# ============================================================

## Serializes the current graphics, audio, and input state into one ConfigFile.
## The control sections are rebuilt on every save so an old key or gamepad-axis
## entry cannot survive after the player changes or removes that binding.

func save_settings() -> void:

	var config: ConfigFile = ConfigFile.new()

	config.load(SAVE_PATH)

	# Graphics settings

	config.set_value("graphics", "vsync", vsync_mode)
	config.set_value("graphics", "window_mode", window_mode)
	config.set_value("graphics", "msaa_2d", msaa_2d)
	config.set_value("graphics", "texture_filter_nearest", texture_filter_nearest)
	config.set_value("graphics", "pixel_snap", pixel_snap_enabled)
	config.set_value("graphics", "fps_limit", fps_limit)

	# Keep the runtime ProjectSettings values synchronized with the saved state.

	ProjectSettings.set_setting(
		"rendering/anti_aliasing/quality/msaa_2d",
		MSAA_SAMPLE_COUNTS[clampi(msaa_2d, 0, MSAA_SAMPLE_COUNTS.size() - 1)]
	)
	ProjectSettings.set_setting(
		"rendering/2d/snap/snap_2d_transforms_to_pixel",
		pixel_snap_enabled
	)

	# Audio settings

	if master_slider:
		config.set_value(
			"audio",
			"master",
			master_slider.value
		)

	if music_slider:
		config.set_value(
			"audio",
			"music",
			music_slider.value
		)

	if sfx_slider:
		config.set_value(
			"audio",
			"sfx",
			sfx_slider.value
		)

	# Control bindings
	# These sections belong exclusively to this settings manager, so rebuilding
	# them guarantees that removed or changed bindings do not remain on disk.

	config.erase_section("keys")
	config.erase_section("gamepad_buttons")
	config.erase_section("gamepad_axes")

	for action_variant in action_names:
		var action: String = str(action_variant)

		# Keyboard binding

		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				config.set_value(
					"keys",
					action,
					int((event as InputEventKey).keycode)
				)
				break

		# Gamepad binding button

		for event in InputMap.action_get_events(action):
			if event is InputEventJoypadButton:
				config.set_value(
					"gamepad_buttons",
					action,
					int((event as InputEventJoypadButton).button_index)
				)
				break

		# Gamepad binding axis

		for event in InputMap.action_get_events(action):
			if event is InputEventJoypadMotion:
				var motion: InputEventJoypadMotion = event as InputEventJoypadMotion
				config.set_value(
					"gamepad_axes",
					action,
					{
						"axis": int(motion.axis),
						"value": float(motion.axis_value)
					}
				)
				break

	var save_error: Error = config.save(SAVE_PATH)

	if save_error != OK:
		push_warning("Failed to save settings: " + error_string(save_error))


## Loads persisted settings, falls back to Inspector defaults, and applies them.
## Graphics are restored first because they affect the runtime immediately; input
## actions are rebuilt afterward from the saved configuration.

func load_settings() -> void:

	var config: ConfigFile = ConfigFile.new()
	var err: Error = config.load(SAVE_PATH)

	# -------------------------
	# Graphics settings
	# -------------------------

	set_graphics_to_inspector_defaults()

	if err == OK and config.has_section("graphics"):
		vsync_mode = clampi(
			int(config.get_value("graphics", "vsync", default_vsync_mode)),
			0,
			2
		)

		window_mode = clampi(
			int(config.get_value("graphics", "window_mode", default_window_mode)),
			0,
			3
		)
		pending_window_mode = window_mode

		var saved_msaa: int = int(
			config.get_value(
				"graphics",
				"msaa_2d",
				default_msaa_2d
			)
		)

		# Convert values saved by older versions, which stored the actual MSAA sample count.

		match saved_msaa:
			0:
				msaa_2d = 0
			2:
				msaa_2d = 1
			4:
				msaa_2d = 2
			8:
				msaa_2d = 3
			_:
				msaa_2d = clampi(saved_msaa, 0, 3)

		texture_filter_nearest = bool(
			config.get_value(
				"graphics",
				"texture_filter_nearest",
				default_texture_filter_nearest
			)
		)

		pixel_snap_enabled = bool(
			config.get_value(
				"graphics",
				"pixel_snap",
				default_pixel_snap_enabled
			)
		)

		fps_limit = int(
			config.get_value(
				"graphics",
				"fps_limit",
				default_fps_limit
			)
		)

		if !FPS_LIMITS.has(fps_limit):
			fps_limit = 60
	else:
		set_graphics_to_inspector_defaults()
		pending_window_mode = window_mode

	apply_graphics_settings()


	# -------------------------
	# Language
	# -------------------------

	var loc_mgr: Node = get_node_or_null(
		"/root/LocalizationManager"
	)

	if loc_mgr != null and loc_mgr.has_method("change_language"):
		var saved_lang: String = String(
			config.get_value(
				"general",
				"language",
				"en"
			)
		)

		loc_mgr.change_language(saved_lang)

	# -------------------------
	# Control bindings
	# -------------------------

	if err != OK:
		return

	for action_variant in action_names:
		var action: String = str(action_variant)

		if !InputMap.has_action(action):
			InputMap.add_action(action)

		# Clear the current bindings before rebuilding them from the saved configuration.

		clear_action_bindings(action)

		# Keyboard binding

		if config.has_section_key("keys", action):
			var keycode: Key = int(config.get_value("keys", action)) as Key
			var key_event: InputEventKey = InputEventKey.new()
			key_event.keycode = keycode
			InputMap.action_add_event(action, key_event)

		# Gamepad binding button

		if config.has_section_key("gamepad_buttons", action):
			var button_index: JoyButton = int(
				config.get_value("gamepad_buttons", action)
			) as JoyButton
			var pad_event: InputEventJoypadButton = InputEventJoypadButton.new()
			pad_event.button_index = button_index
			pad_event.device = -1
			InputMap.action_add_event(action, pad_event)

		# Gamepad binding axis

		if config.has_section_key("gamepad_axes", action):
			var axis_data = config.get_value("gamepad_axes", action)

			if axis_data is Dictionary:
				var motion: InputEventJoypadMotion = InputEventJoypadMotion.new()
				motion.axis = int(axis_data.get("axis", 0)) as JoyAxis
				motion.axis_value = float(axis_data.get("value", 1.0))
				motion.device = -1
				InputMap.action_add_event(action, motion)


# ============================================================
# HELPERS
# ============================================================

func create_title(text: String) -> Label:

	var label: Label = Label.new()

	label.text = text
	label.add_theme_font_size_override(
		"font_size",
		13
	)

	return label


func create_subtitle(text: String) -> Label:

	var label: Label = Label.new()

	label.text = text
	label.add_theme_font_size_override(
		"font_size",
		9
	)

	return label


func create_separator() -> HSeparator:

	var sep: HSeparator = HSeparator.new()

	sep.custom_minimum_size.y = 4

	return sep


func clear_container(container: Container) -> void:

	for child in container.get_children():

		child.queue_free()


# ============================================================
# OPEN / CLOSE
# ============================================================

func open_settings() -> void:

	if opened:
		return

	opened = true

	root_panel.visible = true

	if tween:
		tween.kill()

	root_panel.position.x = -panel_width * ui_scale

	tween = create_tween()

	tween.set_trans(
		Tween.TRANS_QUAD
	).set_ease(
		Tween.EASE_OUT
	)

	tween.tween_property(
		root_panel,
		"position:x",
		0.0,
		animation_time
	)


## Animates the panel out of view and hides it after the transition completes.
## Waiting for the tween prevents the panel from being hidden before the closing
## animation has finished.

func close_settings() -> void:

	if !opened:
		return

	opened = false

	if tween:
		tween.kill()

	tween = create_tween()

	tween.set_trans(
		Tween.TRANS_QUAD
	).set_ease(
		Tween.EASE_IN
	)

	tween.tween_property(
		root_panel,
		"position:x",
		-panel_width * ui_scale,
		animation_time
	)

	await tween.finished

	root_panel.visible = false


func open_settings_instant() -> void:

	opened = true

	root_panel.visible = true

	root_panel.position.x = 0.0


func close_settings_instant() -> void:

	opened = false

	root_panel.visible = false

	root_panel.position.x = -panel_width * ui_scale


func toggle_settings() -> void:

	if opened:
		close_settings()
	else:
		open_settings()
