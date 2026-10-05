// SDL3 + OpenGL 4.4 渲染层:窗口 / GL 上下文 / 图元批。
// 渲染是数据管线终端:只读消费 canvas/font,绝不写回模型数据。
// 屏幕坐标 = 像素,左上原点,Y 向下。每帧:BeginFrame → 绘制 → EndFrame。
package render

import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import fnt "../font"
import mem "../memory"
import paths "../paths"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

INIT_WINDOW_WIDTH :: 1920
INIT_WINDOW_HEIGHT :: 1080
INIT_WINDOW_TITLE :: "CETerm"

window : ^s3.Window
gl_context : s3.GLContext
screen_w, screen_h : f32

// ---------------------------------------------------------------------------
// 着色器(源码外置 <资源根>/shader/:main.vert / main.frag / background.frag;资源根见 paths 模块)
// ---------------------------------------------------------------------------

program : u32
main_vs : u32 // 主/背景 pass 共用顶点 shader(main.vert)
u_screen_size : i32

// 读文件 + 编译 shader(失败 = 0;路径相对工作目录 = 可执行文件所在)
loadShader :: proc(path : string, kind : u32) -> u32 {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("AGAIN! we can't find a correct background shader in given path! so YOU should handle it! it is not MY job to deal with that!", path)
		return 0
	}
	defer delete(data)
	cs := strings.clone_to_cstring(string(data))
	defer delete(cs)
	return compileShader(kind, cs)
}

// ---------------------------------------------------------------------------
// 四边形批量:同纹理的四边形攒一批,一次 draw call
// ---------------------------------------------------------------------------

Vertex :: struct {
	x, y : f32, // 屏幕像素
	u, v : f32, // UV
	r, g, b, a : f32,
}

MAX_QUADS :: 16384 // 满屏格子(~120x40x2)不中途 flush;顶点静态 3MB
quad_verts : [MAX_QUADS * 6]Vertex
quad_count : int
current_tex : u32
white_tex : u32
vao, vbo : u32

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

// 窗口图标:一张 256×256 PNG(SDL3 自带 PNG 解码,资源根见 paths 模块)。
// 文件缺失不算致命 —— 开发构建或裁剪过的资源目录仍要能起窗口,所以静默跳过。
setWindowIcon :: proc() {
	path := strings.clone_to_cstring(paths.Resource("icon/ceterm.png"), context.temp_allocator)
	icon := s3.LoadSurface(path)
	if icon == nil {
		return
	}
	defer s3.DestroySurface(icon)
	s3.SetWindowIcon(window, icon)
}

Init :: proc() -> bool {
	if !s3.Init({.VIDEO}) {
		fmt.eprintln("SDL3 init failed. Guess what? I won't serve you anymore! GO using other terminal emulator such as the WINDOW TERMINAL. This is who specially prepared for users like YOU.", s3.GetError())
		return false
	}
	window = s3.CreateWindow(
		INIT_WINDOW_TITLE,
		INIT_WINDOW_WIDTH,
		INIT_WINDOW_HEIGHT,
		s3.WINDOW_OPENGL | s3.WINDOW_RESIZABLE
	)
	if window == nil {
		fmt.eprintln("FAILED FAILED and FAILED. You can't just create A window! Congratulations!", s3.GetError())
		return false
	}
	setWindowIcon()

	s3.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(s3.GLProfile{.CORE}))
	s3.GL_SetAttribute(.DOUBLEBUFFER, 1)
	s3.GL_SetAttribute(.MULTISAMPLEBUFFERS, 1)
	s3.GL_SetAttribute(.MULTISAMPLESAMPLES, 4)

	gl_context = s3.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintln("The Khronos say: You don's even deserve to have an available GL_Context.", s3.GetError())
		return false
	}
	if !s3.GL_MakeCurrent(window, gl_context) {
		fmt.eprintln("The Khronos say: Even if you have a GL_Context, you don't deserve to bind it.", s3.GetError())
		return false
	}

	gl.load_up_to(
		4,
		4,
		proc(p : rawptr, name : cstring) {
			(cast(^rawptr)p)^ = cast(rawptr)s3.GL_GetProcAddress(name)
		}
	)

	s3.GL_SetSwapInterval(0) // 初始 = 关 vsync(性能观测用);SetVSync 切换

	main_vs = loadShader(paths.Resource("shader/main.vert"), gl.VERTEX_SHADER)
	main_fs := loadShader(paths.Resource("shader/main.frag"), gl.FRAGMENT_SHADER)
	program = linkProgram(main_vs, main_fs)
	if program == 0 {
		return false
	}
	u_screen_size = gl.GetUniformLocation(program, "uScreenSize")
	initBatch()
	initWhiteTexture()
	InitBackgroundShader() // 读 resource/shader/background.frag(可先用 SetBackgroundShader 自愈)
	return true
}

Quit :: proc() {
	BackgroundShaderQuit()
	gl.DeleteProgram(program)
	gl.DeleteShader(main_vs)
	gl.DeleteBuffers(1, &vbo)
	gl.DeleteVertexArrays(1, &vao)
	gl.DeleteTextures(1, &white_tex)
	s3.GL_DestroyContext(gl_context)
	s3.DestroyWindow(window)
	s3.Quit()
}

// 当前窗口物理尺寸(像素):GL framebuffer 的真实尺寸,渲染/布局都用它。
// 注意不能用 s3.GetWindowSize(那是逻辑尺寸/点,受 DPI 缩放影响)。
GetWindowSize :: proc() -> (w, h : u32) {
	cw, ch : c.int
	s3.GetWindowSizeInPixels(window, &cw, &ch)
	return u32(cw), u32(ch)
}

// 窗口指针(供 input 启用文本输入等)
GetWindow :: proc() -> ^s3.Window {
	return window
}

// ---------------------------------------------------------------------------
// 窗口标题:OS 标题栏 = 焦点 console 的应用标题(OSC 0/2)。空 = 启动标题
// (INIT_WINDOW_TITLE),绝不回落 Page.title —— 页标题属于 tabbar,程序没自报标题时
// 标题栏就该保持静止,而不是显示页序号。仅变化时落 SDL。
// ---------------------------------------------------------------------------
WINDOW_TITLE_MAX :: 192

window_title : [WINDOW_TITLE_MAX + 1]u8
window_title_len : int

SyncWindowTitle :: proc(app_title : string) {
	if window == nil {
		return
	}
	t := app_title
	if len(t) == 0 {
		t = INIT_WINDOW_TITLE
	}
	n := min(len(t), WINDOW_TITLE_MAX)
	if n == window_title_len && string(window_title[:n]) == string(window_title[:window_title_len]) {
		return // 未变化:不打扰 SDL
	}
	copy(window_title[:n], t[:n])
	window_title[n] = 0
	window_title_len = n
	s3.SetWindowTitle(window, cstring(&window_title[0]))
}

// ---------------------------------------------------------------------------
// 无边框(去系统标题栏/边框):渲染内容不变,仅窗口装饰变化。
// 无边框后窗口无法用标题栏拖动/边缘缩放(后续需要再加 F11 全屏或自绘拖拽)。
// ---------------------------------------------------------------------------
borderless_on : bool

SetWindowBorderless :: proc(on : bool) {
	borderless_on = on
	_ = s3.SetWindowBordered(window, !on)
}

GetWindowBorderless :: proc() -> bool {
	return borderless_on
}

// ---------------------------------------------------------------------------
// 垂直同步开关(默认关:帧率 = 真实渲染上限,性能观测;开 = 跟随刷新率)
// ---------------------------------------------------------------------------
vsync_on : bool

SetVSync :: proc(on : bool) {
	vsync_on = on
	s3.GL_SetSwapInterval(i32(on)) // 0 = 关(交换不等待),1 = 开(垂直同步)
}

// 当前垂直同步状态(命令 vsync 三态需要读取)
GetVSync :: proc() -> bool {
	return vsync_on
}

// ---------------------------------------------------------------------------
// 主循环模式开关:阻塞(事件驱动)vs 忙等(无条件每帧)
// ---------------------------------------------------------------------------
// 与 vsync 同形,因为它解决同一类问题:出可疑行为时用一条开关把主循环退回
// "旧行为"来隔离故障。放在 render 是因为 main 被 command 依赖 —— 开关必须在
// 叶子模块里,命令层才够得着(与 vsync 同理)。
//
//   阻塞 on (默认)  没活时睡在 SDL 事件队列上,静止画面 CPU ≈ 0
//   阻塞 off        每帧无条件跑,回到加阻塞之前的行为(CPU 满,行为最保守)
block_loop_on : bool = true

SetBlockLoop :: proc(on : bool) {
	block_loop_on = on
}

GetBlockLoop :: proc() -> bool {
	return block_loop_on
}

// ---------------------------------------------------------------------------
// 帧
// ---------------------------------------------------------------------------


Update :: proc() {
	BeginFrame()
	UpdateIMEArea() // 每帧把光标位置喂给 IME(候选窗跟随光标)
	DrawFrame() // 内含背景 pass(scene 层统一帧序)
	EndFrame()
}

BeginFrame :: proc() {
	FpsTick() // FPS 累加(与标签可不可见无关;开启时立刻有值)
	w, h := GetWindowSize()
	screen_w, screen_h = f32(w), f32(h)

	gl.Viewport(0, 0, c.int(w), c.int(h))
	gl.ClearColor(0.07, 0.09, 0.12, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)

	quad_count = 0
	bg_quad_count = 0
	current_tex = 0

	// 主渲染状态(上一帧 nanovg flush 可能改动 blend/状态,这里重置)
	gl.UseProgram(program)
	gl.BindVertexArray(vao)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.DEPTH_TEST)
	gl.Uniform2f(u_screen_size, screen_w, screen_h)
}

EndFrame :: proc() {
	flushBatch()
	s3.GL_SwapWindow(window)
}

// ---------------------------------------------------------------------------
// 绘制
// ---------------------------------------------------------------------------

// 实心矩形,color = 0xRRGGBB(前景/UI 用:字形、分割条、焦点边框、FPS 等)
DrawRect :: proc(x, y, w, h : f32, color : u32) {
	pushQuad(white_tex, x, y, x + w, y + h, 0, 0, 1, 1, color)
}

// 终端背景矩形(打底 / cell 底色):恒进背景批(帧尾 → FBO → 背景 shader → 屏幕),
// 与字形批分离(字形不受 shader 变换影响);无"纯色模式",纯色 = 改 background.frag。
DrawRectBg :: proc(x, y, w, h : f32, color : u32) {
	pushBgQuad(x, y, x + w, y + h, color)
}

// 单字形,(x, y) = 基线位置;返回前进宽,无字形时按格宽。
// italic = 仿真斜体(位图按行错切,见 pushQuad 的 skew)
DrawRune :: proc(font_h : mem.Handle, cp : rune, x, y : f32, color : u32, italic := false) -> (advance : f32) {
	g, ok := fnt.GetGlyph(font_h, cp)
	if !ok {
		return fnt.GetMetrics(font_h).cell_width
	}
	return pushGlyph(font_h, g, x, y, color, italic)
}

// 内部 glyph id 字形(连体替换结果),(x, y) = 基线位置
DrawGlyphById :: proc(font_h : mem.Handle, gid : u16, x, y : f32, color : u32, italic := false) -> (advance : f32) {
	g, ok := fnt.GetGlyphById(font_h, gid)
	if !ok {
		return fnt.GetMetrics(font_h).cell_width
	}
	return pushGlyph(font_h, g, x, y, color, italic)
}

// 仿真斜体剪切系数(字形底部相对顶部错切,≈11°)
ITALIC_SHEAR :: f32(0.2)

pushGlyph :: proc(font_h : mem.Handle, g : fnt.Glyph, x, y : f32, color : u32, italic := false) -> (advance : f32) {
	tex := fnt.GetAtlasTexture(font_h)
	skew := italic ? ITALIC_SHEAR : f32(0)
	pushQuad(tex, x + g.xoff, y + g.yoff, x + g.xoff + g.bitmap_w, y + g.yoff + g.bitmap_h, g.uv0_x, g.uv0_y, g.uv1_x, g.uv1_y, color, skew)
	return g.advance
}

// 文本,(x, y) = 基线位置
DrawText :: proc(font_h : mem.Handle, text : string, x, y : f32, color : u32) {
	m := fnt.GetMetrics(font_h)
	pen_x, pen_y := x, y
	for r in text {
		if r == '\n' {
			pen_x = x
			pen_y += m.cell_height
			continue
		}
		pen_x += DrawRune(font_h, r, pen_x, pen_y, color)
	}
}

pushQuad :: proc(tex : u32, x0, y0, x1, y1, u0, v0, u1, v1 : f32, color : u32, skew : f32 = 0) {
	if tex != current_tex {
		flushBatch()
		current_tex = tex
		gl.BindTexture(gl.TEXTURE_2D, tex)
	}
	if quad_count >= MAX_QUADS {
		flushBatch()
	}
	writeQuad(&quad_verts, quad_count, x0, y0, x1, y1, u0, v0, u1, v1, color, skew)
	quad_count += 1
}

// 背景批(固定白纹,纯色矩形;批满自动上屏到 FBO)
bg_quad_verts : [MAX_QUADS * 6]Vertex
bg_quad_count : int

pushBgQuad :: proc(x0, y0, x1, y1 : f32, color : u32) {
	if bg_quad_count >= MAX_QUADS {
		flushBgBatch()
	}
	writeQuad(&bg_quad_verts, bg_quad_count, x0, y0, x1, y1, 0, 0, 1, 1, color)
	bg_quad_count += 1
}

// 顶点写入(主批/背景批共用;坐标取整对齐像素网格:字形位图内容已含亚像素偏移
// (sub_x 相位补偿),四舍五入后 1:1 采样清晰,且字形回到设计位置(floor 会整体
// 左移 1px,让贴格子边缘的圆角字符相对高亮背景错位)。
// skew = 仿真斜体:底部顶点相对顶部错切 x += skew*高度(梯形);0 = 矩形
writeQuad :: proc(verts : ^[MAX_QUADS * 6]Vertex, q : int, x0, y0, x1, y1, u0, v0, u1, v1 : f32, color : u32, skew : f32 = 0) {
	fx0, fy0 := math.round(x0), math.round(y0)
	fx1, fy1 := math.round(x1), math.round(y1)
	dx := skew * (fy1 - fy0) // 底部相对顶部的 x 错切
	r := f32(color >> 16 & 0xFF) / 255
	g := f32(color >> 8 & 0xFF) / 255
	b := f32(color & 0xFF) / 255
	// alpha:高字节 0 = 不透明(向后兼容 0xRRGGBB);0xAARRGGBB = 半透明(动画)
	a := f32(1)
	if color >> 24 != 0 {
		a = f32(color >> 24 & 0xFF) / 255
	}
	base := q * 6
	verts[base + 0] = Vertex { fx0, fy0, u0, v0, r, g, b, a }
	verts[base + 1] = Vertex { fx1, fy0, u1, v0, r, g, b, a }
	verts[base + 2] = Vertex { fx1 + dx, fy1, u1, v1, r, g, b, a }
	verts[base + 3] = Vertex { fx1 + dx, fy1, u1, v1, r, g, b, a }
	verts[base + 4] = Vertex { fx0 + dx, fy1, u0, v1, r, g, b, a }
	verts[base + 5] = Vertex { fx0, fy0, u0, v0, r, g, b, a }
}

flushBatch :: proc() {
	if quad_count == 0 {
		return
	}
	// 显式绑回主渲染的 program + VAO;nano vulg 等第三方后端可能改动了 bound 状态
	gl.UseProgram(program)
	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, int(quad_count * 6 * size_of(Vertex)), raw_data(quad_verts[:quad_count * 6]), gl.DYNAMIC_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(quad_count * 6))
	quad_count = 0
}

// 背景批上屏(FBO 已绑定 + 清屏后调用;白纹 + 主 program/VAO)
flushBgBatch :: proc() {
	if bg_quad_count == 0 {
		return
	}
	gl.UseProgram(program)
	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BindTexture(gl.TEXTURE_2D, white_tex)
	gl.BufferData(gl.ARRAY_BUFFER, int(bg_quad_count * 6 * size_of(Vertex)), raw_data(bg_quad_verts[:bg_quad_count * 6]), gl.DYNAMIC_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, i32(bg_quad_count * 6))
	bg_quad_count = 0
}

// ---------------------------------------------------------------------------
// GL 初始化
// ---------------------------------------------------------------------------

compileShader :: proc(kind : u32, src : cstring) -> u32 {
	shader := gl.CreateShader(kind)
	srcs := [?]cstring{src}
	gl.ShaderSource(shader, 1, raw_data(srcs[:]), nil)
	gl.CompileShader(shader)
	status : i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		buf : [2048]byte
		gl.GetShaderInfoLog(shader, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("the fucking shader CAN'T be converted by the GL compilor into a bunch of shit bytecode that can be executed by the GPU(maybe a erotic RTX5090 just like a beauty). A JIT would have compiled the same shit at runtime, called it a feature, and blamed deoptimization when it ran slow. You don't even get that excuse.", string(buf[:]))
		gl.DeleteShader(shader)
		return 0
	}
	return shader
}

linkProgram :: proc(vs, fs : u32) -> u32 {
	program := gl.CreateProgram()
	gl.AttachShader(program, vs)
	gl.AttachShader(program, fs)
	gl.LinkProgram(program)
	status : i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &status)
	if status == 0 {
		buf : [2048]byte
		gl.GetProgramInfoLog(program, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("FAILED to link the program and you should pick up your phone to CALL THE khronos and ask him WHY?", string(buf[:]))
		gl.DeleteProgram(program)
		return 0
	}
	return program
}

initBatch :: proc() {
	gl.GenVertexArrays(1, &vao)
	gl.BindVertexArray(vao)
	gl.GenBuffers(1, &vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)

	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, size_of(Vertex), 0)
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, size_of(Vertex), uintptr(2 * size_of(f32)))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 4, gl.FLOAT, gl.FALSE, size_of(Vertex), uintptr(4 * size_of(f32)))

	gl.ActiveTexture(gl.TEXTURE0)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
}

initWhiteTexture :: proc() {
	gl.GenTextures(1, &white_tex)
	gl.BindTexture(gl.TEXTURE_2D, white_tex)
	pixel : u8 = 255
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R8, 1, 1, 0, gl.RED, gl.UNSIGNED_BYTE, &pixel)
}
