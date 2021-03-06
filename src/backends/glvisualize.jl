#=
TODO
    * move all gl_ methods to GLPlot
    * integrate GLPlot UI
    * clean up corner cases
    * find a cleaner way for extracting properties
    * polar plots
    * labes and axis
    * fix units in all visuals (e.g dotted lines, marker scale, surfaces)
    * why is there so little unicode supported in the font!??!?
=#

const _glvisualize_attr = merge_with_base_supported([
    :annotations,
    :background_color_legend, :background_color_inside, :background_color_outside,
    :foreground_color_grid, :foreground_color_legend, :foreground_color_title,
    :foreground_color_axis, :foreground_color_border, :foreground_color_guide, :foreground_color_text,
    :label,
    :linecolor, :linestyle, :linewidth, :linealpha,
    :markershape, :markercolor, :markersize, :markeralpha,
    :markerstrokewidth, :markerstrokecolor, :markerstrokealpha,
    :fillrange, :fillcolor, :fillalpha,
    :bins, :bar_width, :bar_edges, :bar_position,
    :title, :title_location, :titlefont,
    :window_title,
    :guide, :lims, :ticks, :scale, :flip, :rotation,
    :tickfont, :guidefont, :legendfont,
    :grid, :legend, :colorbar,
    :marker_z,
    :line_z,
    :levels,
    :ribbon, :quiver, :arrow,
    :orientation,
    :overwrite_figure,
    #:polar,
    :normalize, :weights,
    :contours, :aspect_ratio,
    :match_dimensions,
    :clims,
    :inset_subplots,
    :dpi,
    :hover
])
const _glvisualize_seriestype = [
    :path, :shape,
    :scatter, :hexbin,
    :bar, :boxplot,
    :heatmap, :image, :volume,
    :contour, :contour3d, :path3d, :scatter3d, :surface, :wireframe
]
const _glvisualize_style = [:auto, :solid, :dash, :dot, :dashdot]
const _glvisualize_marker = _allMarkers
const _glvisualize_scale = [:identity, :ln, :log2, :log10]



# --------------------------------------------------------------------------------------

function _initialize_backend(::GLVisualizeBackend; kw...)
    @eval begin
        import GLVisualize, GeometryTypes, Reactive, GLAbstraction, GLWindow, Contour
        import GeometryTypes: Point2f0, Point3f0, Vec2f0, Vec3f0, GLNormalMesh, SimpleRectangle
        import FileIO, Images
        export GLVisualize
        import Reactive: Signal
        import GLAbstraction: Style
        import GLVisualize: visualize
        import Plots.GL
        Plots.slice_arg(img::Images.AbstractImage, idx::Int) = img
        is_marker_supported(::GLVisualizeBackend, shape::GLVisualize.AllPrimitives) = true
        is_marker_supported{Img<:Images.AbstractImage}(::GLVisualizeBackend, shape::Union{Vector{Img}, Img}) = true
        is_marker_supported{C<:Colorant}(::GLVisualizeBackend, shape::Union{Vector{Matrix{C}}, Matrix{C}}) = true
        is_marker_supported(::GLVisualizeBackend, shape::Shape) = true
        const GL = Plots
    end
end

function add_backend_string(b::GLVisualizeBackend)
    """
    For those incredibly brave souls who assume full responsibility for what happens next...
    There's an easy way to get what you need for the GLVisualize backend to work:

    Pkg.clone("https://github.com/tbreloff/MetaPkg.jl")
    import MetaPkg
    MetaPkg.checkout("MetaGL")

    See the MetaPkg readme for details...
    """
end

# ---------------------------------------------------------------------------

# initialize the figure/window
# function _create_backend_figure(plt::Plot{GLVisualizeBackend})
#     # init a screen
#
#     GLPlot.init()
# end
const _glplot_deletes = []
function empty_screen!(screen)
    if isempty(_glplot_deletes)
        screen.renderlist = ()
        for c in screen.children
            empty!(c)
        end
        empty!(screen.children)
    else
        for del_signal in _glplot_deletes
            push!(del_signal, true) # trigger delete
        end
        empty!(_glplot_deletes)
    end
    nothing
end
function _create_backend_figure(plt::Plot{GLVisualizeBackend})
    # init a screen
    if isempty(GLVisualize.get_screens())
        s = GLVisualize.glscreen()
        Reactive.stop()
        @async begin
            while isopen(s)
                tic()
                GLWindow.pollevents()
                if Base.n_avail(Reactive._messages) > 0
                    Reactive.run_till_now()
                    GLWindow.render_frame(s)
                    GLWindow.swapbuffers(s)
                end
                yield()
                diff = (1/60) - toq()
                while diff >= 0.001
                    tic()
                    sleep(0.001) # sleep for the minimal amount of time
                    diff -= toq()
                end
            end
            GLWindow.destroy!(s)
            GLVisualize.cleanup_old_screens()
        end
    else
        s = GLVisualize.current_screen()
        empty_screen!(s)
    end
    s
end
# ---------------------------------------------------------------------------

const _gl_marker_map = KW(
    :rect => '■',
    :star5 => '★',
    :diamond => '◆',
    :hexagon => '⬢',
    :cross => '✚',
    :xcross => '❌',
    :utriangle => '▲',
    :dtriangle => '▼',
    :pentagon => '⬟',
    :octagon => '⯄',
    :star4 => '✦',
    :star6 => '🟋',
    :star8 => '✷',
    :vline => '┃',
    :hline => '━',
    :+ => '+',
    :x => 'x',
)

function gl_marker(shape, size)
    shape
end
function gl_marker(shape::Shape, size::FixedSizeArrays.Vec{2,Float32})
    points = Point2f0[Vec{2,Float32}(p)*10f0 for p in zip(shape.x, shape.y)]
    GeometryTypes.GLNormalMesh(points)
end
# create a marker/shape type
function gl_marker(shape::Symbol, msize)
    isa(msize, Array) && (msize = first(msize)) # size doesn't really matter now
    if shape == :rect
        GeometryTypes.HyperRectangle(Vec{2, Float32}(0), msize)
    elseif shape == :circle || shape == :none
        GeometryTypes.HyperSphere(Point{2, Float32}(0), maximum(msize))
    elseif haskey(_gl_marker_map, shape)
        _gl_marker_map[shape]
    elseif haskey(_shapes, shape)
        gl_marker(_shapes[shape], msize)
    else
        error("Shape $shape not supported by GLVisualize")
    end
end

function extract_limits(sp, d, kw_args)
    clims = sp[:clims]
    if is_2tuple(clims)
        if isfinite(clims[1]) && isfinite(clims[2])
          kw_args[:limits] = Vec2f0(clims)
        end
    end
    nothing
end

function extract_marker(d, kw_args)
    dim = Plots.is3d(d) ? 3 : 2
    scaling = dim == 3 ? 0.003 : 2
    if haskey(d, :markersize)
        msize = d[:markersize]
        if isa(msize, AbstractArray)
            kw_args[:scale] = map(x->GeometryTypes.Vec{dim, Float32}(x*scaling), msize)
        else
            kw_args[:scale] = GeometryTypes.Vec{dim, Float32}(msize*scaling)
        end
    end
    if haskey(d, :markershape)
        shape = d[:markershape]
        shape = gl_marker(shape, kw_args[:scale])
        if shape != :none
            kw_args[:primitive] = shape
        end
    end
    # get the color
    key = :markercolor
    haskey(d, key) || return
    c = gl_color(d[key])
    if isa(c, AbstractVector) && d[:marker_z] != nothing
        extract_colornorm(d, kw_args)
        kw_args[:color] = nothing
        kw_args[:color_map] = c
        kw_args[:intensity] = convert(Vector{Float32}, d[:marker_z])
    else
        kw_args[:color] = c
    end
    key = :markerstrokecolor
    haskey(d, key) || return
    c = gl_color(d[key])
    if c != nothing
        if !(isa(c, Colorant) || (isa(c, Vector) && eltype(c) <: Colorant))
            error("Stroke Color not supported: $c")
        end
        kw_args[:stroke_color] = c
        kw_args[:stroke_width] = Float32(d[:markerstrokewidth])
    end
end

function _extract_surface(d::Plots.Surface)
    d.surf
end
function _extract_surface(d::AbstractArray)
    d
end
# TODO when to transpose??
function extract_surface(d)
    map(_extract_surface, (d[:x], d[:y], d[:z]))
end
function topoints{P}(::Type{P}, array)
    P[x for x in zip(array...)]
end
function extract_points(d)
    dim = is3d(d) ? 3 : 2
    array = (d[:x], d[:y], d[:z])[1:dim]
    topoints(Point{dim, Float32}, array)
end
function make_gradient{C<:Colorant}(grad::Vector{C})
    grad
end
function make_gradient(grad::ColorGradient)
    RGBA{Float32}[c for c in grad.colors]
end
make_gradient(c) = make_gradient(cgrad())

function extract_any_color(d, kw_args)
    if d[:marker_z] == nothing
        c = scalar_color(d, :fill)
        extract_c(d, kw_args, :fill)
        if isa(c, Colorant)
            kw_args[:color] = c
        else
            kw_args[:color] = nothing
            kw_args[:color_map] = make_gradient(c)
            clims = d[:subplot][:clims]
            if Plots.is_2tuple(clims)
                if isfinite(clims[1]) && isfinite(clims[2])
                    kw_args[:color_norm] = Vec2f0(clims)
                end
            elseif clims == :auto
                kw_args[:color_norm] = Vec2f0(extrema(d[:y]))
            end
        end
    else
        kw_args[:color] = nothing
        clims = d[:subplot][:clims]
        if Plots.is_2tuple(clims)
            if isfinite(clims[1]) && isfinite(clims[2])
                kw_args[:color_norm] = Vec2f0(clims)
            end
        elseif clims == :auto
            kw_args[:color_norm] = Vec2f0(extrema(d[:y]))
        else
            error("Unsupported limits: $clims")
        end
        kw_args[:intensity] = convert(Vector{Float32}, d[:marker_z])
        kw_args[:color_map] = gl_color_map(d, :marker)
    end
end

function extract_stroke(d, kw_args)
    extract_c(d, kw_args, :line)
    if haskey(d, :linewidth)
        kw_args[:thickness] = d[:linewidth]*3
    end
end
function extract_color(d, sym)
    d[Symbol("$(sym)color")]
end

gl_color(c::PlotUtils.ColorGradient) = c.colors
gl_color{T<:Colorant}(c::Vector{T}) = c
gl_color(c::RGBA{Float32}) = c
gl_color(c::Colorant) = RGBA{Float32}(c)

function gl_color(tuple::Tuple)
    gl_color(tuple...)
end

# convert to RGBA
function gl_color(c, a)
    c = convertColor(c, a)
    RGBA{Float32}(c)
end
function scalar_color(d, sym)
    gl_color(extract_color(d, sym))
end

function gl_color_map(d, sym)
    colors = extract_color(d, sym)
    _gl_color_map(colors)
end
function _gl_color_map(colors::PlotUtils.ColorGradient)
    colors.colors
end
function _gl_color_map(c)
    Plots.default_gradient()
end



dist(a, b) = abs(a-b)
mindist(x, a, b) = min(dist(a, x), dist(b, x))
function gappy(x, ps)
    n = length(ps)
    x <= first(ps) && return first(ps) - x
    for j=1:(n-1)
        p0 = ps[j]
        p1 = ps[min(j+1, n)]
        if p0 <= x && p1 >= x
            return mindist(x, p0, p1) * (isodd(j) ? 1 : -1)
        end
    end
    return last(ps) - x
end
function ticks(points, resolution)
    Float16[gappy(x, points) for x=linspace(first(points),last(points), resolution)]
end


function insert_pattern!(points, kw_args)
    tex = GLAbstraction.Texture(ticks(points, 100), x_repeat=:repeat)
    kw_args[:pattern] = tex
    kw_args[:pattern_length] = Float32(last(points))
end
function extract_linestyle(d, kw_args)
    haskey(d, :linestyle) || return
    ls = d[:linestyle]
    lw = d[:linewidth]
    kw_args[:thickness] = lw
    if ls == :dash
        points = [0.0, lw, 2lw, 3lw, 4lw]
        insert_pattern!(points, kw_args)
    elseif ls == :dot
        tick, gap = lw/2, lw/4
        points = [0.0, tick, tick+gap, 2tick+gap, 2tick+2gap]
        insert_pattern!(points, kw_args)
    elseif ls == :dashdot
        dtick, dgap = lw, lw
        ptick, pgap = lw/2, lw/4
        points = [0.0, dtick, dtick+dgap, dtick+dgap+ptick, dtick+dgap+ptick+pgap]
        insert_pattern!(points, kw_args)
    elseif ls == :dashdotdot
        dtick, dgap = lw, lw
        ptick, pgap = lw/2, lw/4
        points = [0.0, dtick, dtick+dgap, dtick+dgap+ptick, dtick+dgap+ptick+pgap, dtick+dgap+ptick+pgap+ptick,  dtick+dgap+ptick+pgap+ptick+pgap]
        insert_pattern!(points, kw_args)
    end
    extract_c(d, kw_args, :line)
    nothing
end
function hover(to_hover::Vector, to_display, window)
    hover(to_hover[], to_display, window)
end
function get_cam(x)
    if isa(x, GLAbstraction.Context)
        return get_cam(x.children)
    elseif isa(x, Vector)
        return get_cam(first(x))
    elseif isa(x, GLAbstraction.RenderObject)
        return x[:preferred_camera]
    end
end

function hover(to_hover, to_display, window)
    if isa(to_hover, GLAbstraction.Context)
        return hover(to_hover.children, to_display, window)
    end
    area = map(window.inputs[:mouseposition]) do mp
        SimpleRectangle{Int}(round(Int, mp+10)..., 100, 70)
    end
    background = visualize((GLVisualize.ROUNDED_RECTANGLE, Point2f0[0]),
        color=RGBA{Float32}(0,0,0,0), scale=Vec2f0(100, 70), offset=Vec2f0(0),
        stroke_color=RGBA{Float32}(0,0,0,0.4),
        stroke_width=-1.0f0
    )
    mh = GLWindow.mouse2id(window)
    popup = GLWindow.Screen(window, area=area, hidden=true)
    cam = get!(popup.cameras, :perspective) do
        GLAbstraction.PerspectiveCamera(
            popup.inputs, Vec3f0(3), Vec3f0(0),
            keep=Signal(false),
            theta= Signal(Vec3f0(0)), trans= Signal(Vec3f0(0))
        )
    end
    Reactive.preserve(map(mh) do mh
        popup.hidden = !(mh.id == to_hover.id)
    end)

    map(enumerate(to_display)) do id
        i,d = id
        robj = visualize(d)
        viewit = Reactive.droprepeats(map(mh->mh.id == to_hover.id && mh.index == i, mh))
        camtype = get_cam(robj)
        Reactive.preserve(map(viewit) do vi
            if vi
                empty!(popup)
                if camtype == :perspective
                    cam.projectiontype.value = GLVisualize.PERSPECTIVE
                else
                    cam.projectiontype.value = GLVisualize.ORTHOGRAPHIC
                end
                GLVisualize._view(robj, popup, camera=cam)
                GLVisualize._view(background, popup, camera=:fixed_pixel)
                bb = GLAbstraction.boundingbox(robj).value
                mini = minimum(bb)
                w = GeometryTypes.widths(bb)
                wborder = w*0.08f0 #8 percent border
                bb = GeometryTypes.AABB{Float32}(mini-wborder, w+2f0*wborder)
                GLAbstraction.center!(cam, bb)
            end
        end)
    end
    nothing
end

function extract_extrema(d, kw_args)
    xmin,xmax = extrema(d[:x]); ymin,ymax = extrema(d[:y])
    kw_args[:primitive] = GeometryTypes.SimpleRectangle{Float32}(xmin, ymin, xmax-xmin, ymax-ymin)
    nothing
end

function extract_font(font, kw_args)
    kw_args[:family] = font.family
    kw_args[:relative_scale] = font.pointsize*1.5 ./ GLVisualize.glyph_scale!('X')
    kw_args[:color] = gl_color(font.color)
end

function extract_colornorm(d, kw_args)
    clims = d[:subplot][:clims]
    if Plots.is_2tuple(clims)
        if isfinite(clims[1]) && isfinite(clims[2])
            kw_args[:color_norm] = Vec2f0(clims)
        end
    elseif clims == :auto
        z = if haskey(d, :marker_z) && d[:marker_z] != nothing
            d[:marker_z]
        elseif haskey(d, :line_z) && d[:line_z] != nothing
            d[:line_z]
        elseif isa(d[:z], Plots.Surface)
            d[:z].surf
        else
            d[:y]
        end
        kw_args[:color_norm] = Vec2f0(extrema(z))
        kw_args[:intensity] = map(Float32, collect(z))
    end
end
function extract_gradient(d, kw_args, sym)
    key = Symbol("$(sym)color")
    haskey(d, key) || return
    c = make_gradient(d[key])
    kw_args[:color] = nothing
    extract_colornorm(d, kw_args)
    kw_args[:color_map] = c
    return
end
function extract_c(d, kw_args, sym)
    key = Symbol("$(sym)color")
    haskey(d, key) || return
    c = gl_color(d[key])
    kw_args[:color] = nothing
    kw_args[:color_map] = nothing
    kw_args[:color_norm] = nothing
    if isa(c, AbstractVector)
        extract_colornorm(d, kw_args)
        kw_args[:color_map] = c
    else
        kw_args[:color] = c
    end
    return
end

function extract_stroke(d, kw_args, sym)
    key = Symbol("$(sym)strokecolor")
    haskey(d, key) || return
    c = gl_color(d[key])
    if c != nothing
        if !isa(c, Colorant)
            error("Stroke Color not supported: $c")
        end
        kw_args[:stroke_color] = c
        kw_args[:stroke_width] = Float32(d[Symbol("$(sym)strokewidth")]) * 2
    end
    return
end



function draw_grid_lines(sp, grid_segs, thickness, style, model, color)

    kw_args = Dict{Symbol, Any}(
        :model => model
    )
    d = Dict(
        :linestyle => style,
        :linewidth => thickness,
        :linecolor => color
    )
    Plots.extract_linestyle(d, kw_args)
    GL.gl_lines(map(Point2f0, grid_segs.pts), kw_args)
end

function align_offset(startpos, lastpos, atlas, rscale, font, align)
    xscale, yscale = GLVisualize.glyph_scale!('X').*rscale
    xmove = (lastpos-startpos)[1]+xscale
    if align == :top
        return -Vec2f0(xmove/2f0, yscale)
    elseif align == :right
        return -Vec2f0(xmove, yscale/2f0)
    else
        error("Align $align not known")
    end
end
function align_offset(startpos, lastpos, atlas, rscale, font, align::Vec)
    xscale, yscale = GLVisualize.glyph_scale!('X').*rscale
    xmove = (lastpos-startpos)[1]+xscale
    return -Vec2f0(xmove, yscale) .* align
end
function alignment2num(x::Symbol)
    (x in (:hcenter, :vcenter)) && return 0.5
    (x in (:left, :bottom)) && return 0.0
    (x in (:right, :top)) && return 1.0
    0.0 # 0 default, or better to error?
end
function alignment2num(font::Plots.Font)
    Vec2f0(map(alignment2num, (font.halign, font.valign)))
end

function draw_ticks(axis, ticks, align, move, isx, lims, model, text = "", positions = Point2f0[], offsets=Vec2f0[])
    sz = axis[:tickfont].pointsize
    rscale2 = Vec2f0(3/sz)
    m = Reactive.value(model)
    xs, ys = m[1,1], m[2,2]
    rscale = rscale2 ./ Vec2f0(xs, ys)
    atlas = GLVisualize.get_texture_atlas()
    font = GLVisualize.DEFAULT_FONT_FACE
    if !(ticks in (nothing, false))
        # x labels
        flip = axis[:flip]
        for (cv, dv) in zip(ticks...)
            x,y = cv, (flip ? lims[2] : lims[1])
            startpos = Point2f0(isx ? (x,y) : (y,x))-move
            # @show cv dv ymin xi yi
            str = string(dv)
            position = GLVisualize.calc_position(str, startpos, rscale, font, atlas)
            offset = GLVisualize.calc_offset(str, rscale2, font, atlas)
            alignoff = align_offset(startpos, last(position), atlas, rscale, font, align)
            map!(position) do pos
                pos .+ alignoff
            end
            append!(positions, position)
            append!(offsets, offset)
            text *= str
        end
    end
    text, positions, offsets
end
function text(position, text, kw_args)
    text_align = alignment2num(text.font)
    startpos = Vec2f0(position)
    atlas = GLVisualize.get_texture_atlas()
    font = GLVisualize.DEFAULT_FONT_FACE
    rscale = kw_args[:relative_scale]
    m = Reactive.value(kw_args[:model])
    position = GLVisualize.calc_position(text.str, startpos, rscale, font, atlas)
    offset = GLVisualize.calc_offset(text.str, rscale, font, atlas)
    alignoff = align_offset(startpos, last(position), atlas, rscale, font, text_align)
    map!(position) do pos
        pos .+ alignoff
    end
    kw_args[:position] = position
    kw_args[:offset] = offset
    kw_args[:scale_primitive] = true
    visualize(text.str, Style(:default), kw_args)
end

function text_model(font, pivot)
    pv = GeometryTypes.Vec3f0(pivot[1], pivot[2], 0)
    if font.rotation != 0.0
        rot = Float32(deg2rad(font.rotation))
        rotm = GLAbstraction.rotationmatrix_z(rot)
        return GLAbstraction.translationmatrix(pv)*rotm*GLAbstraction.translationmatrix(-pv)
    else
        eye(GeometryTypes.Mat4f0)
    end
end
function gl_draw_axes_2d(sp::Plots.Subplot{Plots.GLVisualizeBackend}, model, area)
    xticks, yticks, spine_segs, grid_segs = Plots.axis_drawing_info(sp)
    xaxis = sp[:xaxis]; yaxis = sp[:yaxis]

    c = Colors.color(Plots.gl_color(sp[:foreground_color_grid]))
    axis_vis = []
    if sp[:grid]
        grid = draw_grid_lines(sp, grid_segs, 1f0, :dot, model, RGBA(c, 0.3f0))
        push!(axis_vis, grid)
    end
    if alpha(xaxis[:foreground_color_border]) > 0
        spine = draw_grid_lines(sp, spine_segs, 1f0, :solid, model, RGBA(c, 1.0f0))
        push!(axis_vis, spine)
    end
    fcolor = Plots.gl_color(xaxis[:foreground_color_axis])

    xlim = Plots.axis_limits(xaxis)
    ylim = Plots.axis_limits(yaxis)
    m = Reactive.value(model)
    xs, ys = m[1,1], m[2,2]
    # TODO: we should make sure we actually need to draw these...
    t, positions, offsets = draw_ticks(xaxis, xticks, :top, Point2f0(0, 7/ys), true, ylim, model)
    t, positions, offsets = draw_ticks(yaxis, yticks, :right, Point2f0(7/xs, 0), false, xlim, model, t, positions, offsets)
    sz = xaxis[:tickfont].pointsize
    kw_args = Dict{Symbol, Any}(
        :position => positions,
        :offset => offsets,
        :color => fcolor,
        :relative_scale =>  Vec2f0(3/sz),
        :model => model,
        :scale_primitive => false
    )
    if !(xaxis[:ticks] in (nothing,false,:none))
        push!(axis_vis, visualize(t, Style(:default), kw_args))
    end
    area_w = GeometryTypes.widths(area)
    if sp[:title] != ""
        tf = sp[:titlefont]; color = gl_color(sp[:foreground_color_title])
        font = Plots.Font(tf.family, tf.pointsize, :hcenter, :top, tf.rotation, color)
        xy = Point2f0(area.w/2, area_w[2])
        kw = Dict(:model => text_model(font, xy), :scale_primitive=>true)
        extract_font(font, kw)
        t = PlotText(sp[:title], font)
        push!(axis_vis, text(xy, t, kw))
    end
    if xaxis[:guide] != ""
        tf = xaxis[:guidefont]; color = gl_color(xaxis[:foreground_color_guide])
        xy = Point2f0(area.w/2, 0)
        font = Plots.Font(tf.family, tf.pointsize, :hcenter, :bottom, tf.rotation, color)
        kw = Dict(:model => text_model(font, xy), :scale_primitive=>true)
        t = PlotText(xaxis[:guide], font)
        extract_font(font, kw)
        push!(axis_vis, text(xy, t, kw))
    end

    if yaxis[:guide] != ""
        tf = yaxis[:guidefont]; color = gl_color(yaxis[:foreground_color_guide])
        font = Plots.Font(tf.family, tf.pointsize, :hcenter, :top, 90f0, color)
        xy = Point2f0(0, area.h/2)
        kw = Dict(:model => text_model(font, xy), :scale_primitive=>true)
        t = PlotText(yaxis[:guide], font)
        extract_font(font, kw)
        push!(axis_vis, text(xy, t, kw))
    end

    axis_vis
end

function gl_draw_axes_3d(sp, model)
    x = Plots.axis_limits(sp[:xaxis])
    y = Plots.axis_limits(sp[:yaxis])
    z = Plots.axis_limits(sp[:zaxis])

    min = Vec3f0(x[1], y[1], z[1])
    visualize(
        GeometryTypes.AABB{Float32}(min, Vec3f0(x[2], y[2], z[2])-min),
        :grid, model=model
    )
end

function gl_bar(d, kw_args)
    x, y = d[:x], d[:y]
    nx, ny = length(x), length(y)
    axis = d[:subplot][isvertical(d) ? :xaxis : :yaxis]
    cv = [discrete_value!(axis, xi)[1] for xi=x]
    x = if nx == ny
        cv
    elseif nx == ny + 1
        0.5diff(cv) + cv[1:end-1]
    else
        error("bar recipe: x must be same length as y (centers), or one more than y (edges).\n\t\tlength(x)=$(length(x)), length(y)=$(length(y))")
    end
    if haskey(kw_args, :stroke_width) # stroke is inside for bars
        #kw_args[:stroke_width] = -kw_args[:stroke_width]
    end
    # compute half-width of bars
    bw = nothing
    hw = if bw == nothing
        mean(diff(x))
    else
        Float64[cycle(bw,i)*0.5 for i=1:length(x)]
    end

    # make fillto a vector... default fills to 0
    fillto = d[:fillrange]
    if fillto == nothing
        fillto = 0
    end
    # create the bar shapes by adding x/y segments
    positions, scales = Array(Point2f0, ny), Array(Vec2f0, ny)
    m = Reactive.value(kw_args[:model])
    sx, sy = m[1,1], m[2,2]
    for i=1:ny
        center = x[i]
        hwi = abs(cycle(hw,i)); yi = y[i]; fi = cycle(fillto,i)
        if Plots.isvertical(d)
            sz = (hwi*sx, yi*sy)
        else
            sz = (yi*sx, hwi*2*sy)
        end
        positions[i] = (center-hwi*0.5, fi)
        scales[i] = sz
    end

    kw_args[:scale] = scales
    kw_args[:offset] = Vec2f0(0)
    visualize((GLVisualize.RECTANGLE, positions), Style(:default), kw_args)
    #[]
end

const _box_halfwidth = 0.4

notch_width(q2, q4, N) = 1.58 * (q4-q2)/sqrt(N)

function gl_boxplot(d, kw_args)
    kwbox = copy(kw_args)
    range = 1.5; notch = false
    x, y = d[:x], d[:y]
    glabels = sort(collect(unique(x)))
    warning = false
    outliers_x, outliers_y = zeros(0), zeros(0)

    box_pos = Point2f0[]
    box_scale = Vec2f0[]
    outliers = Point2f0[]
    t_segments = Point2f0[]
    m = Reactive.value(kw_args[:model])
    sx, sy = m[1,1], m[2,2]
    for (i,glabel) in enumerate(glabels)
        # filter y
        values = y[filter(i -> cycle(x,i) == glabel, 1:length(y))]
        # compute quantiles
        q1,q2,q3,q4,q5 = quantile(values, linspace(0,1,5))
        # notch
        n = Plots.notch_width(q2, q4, length(values))
        # warn on inverted notches?
        if notch && !warning && ( (q2>(q3-n)) || (q4<(q3+n)) )
            warn("Boxplot's notch went outside hinges. Set notch to false.")
            warning = true # Show the warning only one time
        end

        # make the shape
        center = Plots.discrete_value!(d[:subplot][:xaxis], glabel)[1]
        hw = d[:bar_width] == nothing ? Plots._box_halfwidth*2 : cycle(d[:bar_width], i)
        l, m, r = center - hw/2, center, center + hw/2

        # internal nodes for notches
        L, R = center - 0.5 * hw, center + 0.5 * hw
        # outliers
        if Float64(range) != 0.0  # if the range is 0.0, the whiskers will extend to the data
            limit = range*(q4-q2)
            inside = Float64[]
            for value in values
                if (value < (q2 - limit)) || (value > (q4 + limit))
                    push!(outliers, (center, value))
                else
                    push!(inside, value)
                end
            end
            # change q1 and q5 to show outliers
            # using maximum and minimum values inside the limits
            q1, q5 = extrema(inside)
        end
        # Box
        if notch
            push!(t_segments, (m, q1), (l, q1), (r, q1), (m, q1), (m, q2))# lower T
            push!(box_pos, (l, q2));push!(box_scale, (hw*sx, n*sy)) # lower box
            push!(box_pos, (l, q4));push!(box_scale, (hw*sx, n*sy)) # upper box
            push!(t_segments, (m, q5), (l, q5), (r, q5), (m, q5), (m, q4))# upper T

        else
            push!(t_segments, (m, q2), (m, q1), (l, q1), (r, q1))# lower T
            push!(box_pos, (l, q2)); push!(box_scale, (hw*sx, (q3-q2)*sy)) # lower box
            push!(box_pos, (l, q4)); push!(box_scale, (hw*sx, (q3-q4)*sy)) # upper box
            push!(t_segments, (m, q4), (m, q5), (r, q5), (l, q5))# upper T
        end
    end
    kwbox = Dict{Symbol, Any}(
        :scale => box_scale,
        :model => kw_args[:model],
        :offset => Vec2f0(0),
    )
    extract_marker(d, kw_args)
    outlier_kw = Dict(
        :model => kw_args[:model],
        :color =>  scalar_color(d, :fill),
        :stroke_width => Float32(d[:markerstrokewidth]),
        :stroke_color => scalar_color(d, :markerstroke),
    )
    lines_kw = Dict(
        :model => kw_args[:model],
        :stroke_width =>  d[:linewidth],
        :stroke_color =>  scalar_color(d, :fill),
    )
    vis1 = GLVisualize.visualize((GLVisualize.RECTANGLE, box_pos), Style(:default), kwbox)
    vis2 = GLVisualize.visualize((GLVisualize.CIRCLE, outliers), Style(:default), outlier_kw)
    vis3 = GLVisualize.visualize(t_segments, Style(:linesegment), lines_kw)
    [vis1, vis2, vis3]
end


# ---------------------------------------------------------------------------
function gl_viewport(bb, rect)
    l, b, bw, bh = bb
    rw, rh = rect.w, rect.h
    GLVisualize.SimpleRectangle(
        round(Int, rect.x + rw * l),
        round(Int, rect.y + rh * b),
        round(Int, rw * bw),
        round(Int, rh * bh)
    )
end

function to_modelmatrix(rect, subrect, rel_plotarea, sp)
    xmin, xmax = Plots.axis_limits(sp[:xaxis])
    ymin, ymax = Plots.axis_limits(sp[:yaxis])
    mini, maxi = Vec3f0(xmin, ymin, 0), Vec3f0(xmax, ymax, 1)
    if Plots.is3d(sp)
        zmin, zmax = Plots.axis_limits(sp[:zaxis])
        mini, maxi = Vec3f0(xmin, ymin, zmin), Vec3f0(xmax, ymax, zmax)
        s = Vec3f0(1) ./ (maxi-mini)
        return GLAbstraction.scalematrix(s)*GLAbstraction.translationmatrix(-mini)
    end
    l, b, bw, bh = rel_plotarea
    w, h = rect.w*bw, rect.h*bh
    x, y = rect.w*l - subrect.x, rect.h*b - subrect.y
    t = -mini
    s = Vec3f0(w, h, 1) ./ (maxi-mini)
    GLAbstraction.translationmatrix(Vec3f0(x,y,0))*GLAbstraction.scalematrix(s)*GLAbstraction.translationmatrix(t)
end

# ----------------------------------------------------------------

function _display(plt::Plot{GLVisualizeBackend})
    screen = plt.o
    empty_screen!(screen)
    sw, sh = plt[:size]
    sw, sh = sw*px, sh*px
    # TODO: use plt.subplots... plt.spmap can't be trusted
    for (name, sp) in plt.spmap
        _3d = Plots.is3d(sp)
        # camera = :perspective
        # initialize the sub-screen for this subplot
        # note: we create a lift function to update the size on resize

        rel_bbox = Plots.bbox_to_pcts(bbox(sp), sw, sh)
        sub_area = map(screen.area) do rect
            Plots.gl_viewport(rel_bbox, rect)
        end
        c = plt[:background_color_outside]
        sp_screen = GLVisualize.Screen(
            screen, name = name, color = c,
            area = sub_area
        )
        cam = get!(sp_screen.cameras, :perspective) do
            inside = sp_screen.inputs[:mouseinside]
            theta = _3d ? nothing : Signal(Vec3f0(0)) # surpress rotation for 2D (nothing will get usual rotation controle)
            GLAbstraction.PerspectiveCamera(
                sp_screen.inputs, Vec3f0(3), Vec3f0(0),
                keep=inside, theta=theta
            )
        end

        sp.o = sp_screen
        rel_plotarea = Plots.bbox_to_pcts(plotarea(sp), sw, sh)
        model_m = map(Plots.to_modelmatrix, screen.area, sub_area, Signal(rel_plotarea), Signal(sp))
        for ann in sp[:annotations]
            x, y, plot_text = ann
            txt_args = Dict{Symbol, Any}(:model => eye(GeometryTypes.Mat4f0))
            x, y, _1, _1 = Reactive.value(model_m) * Vec{4,Float32}(x, y, 0, 1)
            extract_font(plot_text.font, txt_args)
            t = text(Point2f0(x, y), plot_text, txt_args)
            GLVisualize._view(t, sp_screen, camera=cam)
        end
        # loop over the series and add them to the subplot
        if !_3d
            axis = gl_draw_axes_2d(sp, model_m, Reactive.value(sub_area))
            GLVisualize._view(axis, sp_screen, camera=cam)
            cam.projectiontype.value = GLVisualize.ORTHOGRAPHIC
            Reactive.run_till_now() # make sure Reactive.push! arrives
            GLAbstraction.center!(cam,
                GeometryTypes.AABB(
                    Vec3f0(-10), Vec3f0((GeometryTypes.widths(sp_screen)+20f0)..., 1)
                )
            )
        else
            axis = gl_draw_axes_3d(sp, model_m)
            GLVisualize._view(axis, sp_screen, camera=cam)
            push!(cam.projectiontype, GLVisualize.PERSPECTIVE)
        end
        for series in  Plots.series_list(sp)
            d = series.d
            st = d[:seriestype]; kw_args = KW() # exctract kw
            kw_args[:model] = model_m # add transformation
            if !_3d # 3D is treated differently, since we need boundingboxes for camera
                kw_args[:boundingbox] = nothing # don't calculate bb, we dont need it
            end

            if st in (:surface, :wireframe)
                x, y, z = extract_surface(d)
                extract_gradient(d, kw_args, :fill)
                z = Plots.transpose_z(d, z, false)
                if isa(x, AbstractMatrix) && isa(y, AbstractMatrix)
                    x, y = Plots.transpose_z(d, x, false), Plots.transpose_z(d, y, false)
                end
                if st == :wireframe
                    kw_args[:wireframe] = true
                    kw_args[:stroke_color] = d[:linecolor]
                    kw_args[:stroke_width] = Float32(d[:linewidth]/100f0)
                end
                vis = GL.gl_surface(x, y, z, kw_args)
            elseif (st in (:path, :path3d)) && d[:linewidth] > 0
                kw = copy(kw_args)
                points = Plots.extract_points(d)
                extract_linestyle(d, kw)
                vis = GL.gl_lines(points, kw)
                if d[:markershape] != :none
                    kw = copy(kw_args)
                    extract_stroke(d, kw)
                    extract_marker(d, kw)
                    vis2 = GL.gl_scatter(copy(points), kw)
                    vis = [vis; vis2]
                end
                if d[:fillrange] != nothing
                    kw = copy(kw_args)
                    fr = d[:fillrange]
                    ps = if all(x->x>=0, diff(d[:x])) # if is monotonic
                        vcat(points, Point2f0[(points[i][1], cycle(fr, i)) for i=length(points):-1:1])
                    else
                        points
                    end
                    extract_c(d, kw, :fill)
                    vis = [GL.gl_poly(ps, kw), vis]
                end
            elseif st in (:scatter, :scatter3d) #|| d[:markershape] != :none
                extract_marker(d, kw_args)
                points = extract_points(d)
                vis = GL.gl_scatter(points, kw_args)
            elseif st == :shape
                extract_c(d, kw_args, :fill)
                vis = GL.gl_shape(d, kw_args)
            elseif st == :contour
                x,y,z = extract_surface(d)
                z = transpose_z(d, z, false)
                extract_extrema(d, kw_args)
                extract_gradient(d, kw_args, :fill)
                kw_args[:fillrange] = d[:fillrange]
                kw_args[:levels] = d[:levels]

                vis = GL.gl_contour(x,y,z, kw_args)
            elseif st == :heatmap
                x,y,z = extract_surface(d)
                extract_gradient(d, kw_args, :fill)
                extract_extrema(d, kw_args)
                extract_limits(sp, d, kw_args)
                vis = GL.gl_heatmap(x,y,z, kw_args)
            elseif st == :bar
                extract_c(d, kw_args, :fill)
                extract_stroke(d, kw_args, :marker)
                vis = gl_bar(d, kw_args)
            elseif st == :image
                extract_extrema(d, kw_args)
                z = transpose_z(series, d[:z].surf, false)
                vis = GL.gl_image(z, kw_args)
            elseif st == :boxplot
                 extract_c(d, kw_args, :fill)
                 vis = gl_boxplot(d, kw_args)
             elseif st == :volume
                  volume = d[:y]
                  _d = copy(d)
                  _d[:y] = 0:1
                  _d[:x] = 0:1
                  kw_args = KW()
                  extract_gradient(_d, kw_args, :fill)
                  vis = visualize(volume.v, Style(:default), kw_args)
             else
                error("failed to display plot type $st")
            end
            if isa(vis, Array) && isempty(vis)
                continue # nothing to see here
            end
            GLVisualize._view(vis, sp_screen, camera=cam)
            if haskey(d, :hover) && !(d[:hover] in (false, :none, nothing))
                hover(vis, d[:hover], sp_screen)
            end
            if isdefined(:GLPlot) && isdefined(Main.GLPlot, :(register_plot!))
                del_signal = Main.GLPlot.register_plot!(vis, sp_screen)
                append!(_glplot_deletes, del_signal)
            end
        end
        if _3d
            GLAbstraction.center!(sp_screen)
        end
    end
    Reactive.post_empty()
    yield()
end

function _show(io::IO, ::MIME"image/png", plt::Plot{GLVisualizeBackend})
    _display(plt)
    GLWindow.pollevents()
    yield()
    if Base.n_avail(Reactive._messages) > 0
        Reactive.run_till_now()
    end
    GLWindow.render_frame(plt.o)
    GLWindow.swapbuffers(plt.o)
    buff = GLWindow.screenbuffer(plt.o)
    png = Images.Image(buff,
        colorspace = "sRGB",
        spatialorder = ["y", "x"]
    )
    FileIO.save(FileIO.Stream(FileIO.DataFormat{:PNG}, io), png)
end


function gl_image(img, kw_args)
    rect = kw_args[:primitive]
    kw_args[:primitive] = GeometryTypes.SimpleRectangle{Float32}(rect.x, rect.y, rect.h, rect.w) # seems to be flipped
    visualize(img, Style(:default), kw_args)
end

function handle_segment{P}(lines, line_segments, points::Vector{P}, segment)
    (isempty(segment) || length(segment) < 2) && return
    if length(segment) == 2
         append!(line_segments, view(points, segment))
    elseif length(segment) == 3
        p = view(points, segment)
        push!(line_segments, p[1], p[2], p[2], p[3])
    else
        append!(lines, view(points, segment))
        push!(lines, P(NaN))
    end
end

function gl_lines(points, kw_args)
    result = []
    isempty(points) && return result
    P = eltype(points)
    lines = P[]
    line_segments = P[]
    last = 1
    for (i,p) in enumerate(points)
        if isnan(p) || i==length(points)
            _i = isnan(p) ? i-1 : i
            handle_segment(lines, line_segments, points, last:_i)
            last = i+1
        end
    end
    if !isempty(lines)
        pop!(lines) # remove last NaN
        push!(result, visualize(lines, Style(:lines), kw_args))
    end
    if !isempty(line_segments)
        push!(result, visualize(line_segments, Style(:linesegment), kw_args))
    end
    return result
end
function gl_shape(d, kw_args)
    points = Plots.extract_points(d)
    result = []
    for rng in iter_segments(d[:x], d[:y])
        ps = points[rng]
        meshes = gl_poly(ps, kw_args)
        append!(result, meshes)
    end
    result
end
tovec2(x::FixedSizeArrays.Vec{2, Float32}) = x
tovec2(x::AbstractVector) = map(tovec2, x)
tovec2(x::FixedSizeArrays.Vec) = Vec2f0(x[1], x[2])


function gl_scatter(points, kw_args)
    prim = get(kw_args, :primitive, GeometryTypes.Circle)
    if isa(prim, GLNormalMesh)
        kw_args[:scale] = map(kw_args[:model]) do m
            s = m[1,1], m[2,2], m[3,3]
            1f0./Vec3f0(s)
        end
    else # 2D prim
        kw_args[:scale] = tovec2(kw_args[:scale])
    end
    if haskey(kw_args, :stroke_width)
        s = Reactive.value(kw_args[:scale])
        sw = kw_args[:stroke_width]
        if sw*5 > cycle(Reactive.value(s), 1)[1] # restrict marker stroke to 1/10th of scale (and handle arrays of scales)
            kw_args[:stroke_width] = s[1]/5f0
        end
    end
    kw_args[:scale_primitive] = false
    visualize((prim, points), Style(:default), kw_args)
end


function gl_poly(points, kw_args)
    last(points) == first(points) && pop!(points)
    polys = GeometryTypes.split_intersections(points)
    result = []
    for poly in polys
        mesh = GLNormalMesh(poly) # make polygon
        if !isempty(GeometryTypes.faces(mesh)) # check if polygonation has any faces
            push!(result, GLVisualize.visualize(mesh, Style(:default), kw_args))
        else
            warn("Couldn't draw the polygon: $points")
        end
    end
    result
end

function gl_surface(x,y,z, kw_args)
    if isa(x, Range) && isa(y, Range)
        main = z
        kw_args[:ranges] = (x, y)
    else
        if isa(x, AbstractMatrix) && isa(y, AbstractMatrix)
            main = map(s->map(Float32, s), (x, y, z))
        elseif isa(x, AbstractVector) || isa(y, AbstractVector)
            x = Float32[x[i] for i=1:size(z,1), j=1:size(z,2)]
            y = Float32[y[j] for i=1:size(z,1), j=1:size(z,2)]
            main = (x, y, map(Float32, z))
        else
            error("surface: combination of types not supported: $(typeof(x)) $(typeof(y)) $(typeof(z))")
        end
        if get(kw_args, :wireframe, false)
            points = map(Point3f0, zip(vec(x), vec(y), vec(z)))
            faces = Cuint[]
            idx = (i,j) -> sub2ind(size(z), i, j) - 1
            for i=1:size(z,1), j=1:size(z,2)
                i < size(z,1) && push!(faces, idx(i, j), idx(i+1, j))
                j < size(z,2) && push!(faces, idx(i, j), idx(i, j+1))
            end
            color = get(kw_args, :stroke_color, RGBA{Float32}(0,0,0,1))
            kw_args[:color] = color
            kw_args[:thickness] = get(kw_args, :stroke_width, 1f0)
            kw_args[:indices] = faces
            delete!(kw_args, :stroke_color)
            delete!(kw_args, :stroke_width)

            return visualize(points, Style(:linesegment), kw_args)
        end
    end
    return visualize(main, Style(:surface), kw_args)
end


function gl_contour(x,y,z, kw_args)
    if kw_args[:fillrange] != nothing
        delete!(kw_args, :intensity)
        I = GLVisualize.Intensity{1, Float32}
        main = I[z[j,i] for i=1:size(z, 2), j=1:size(z, 1)]
        return visualize(main, Style(:default), kw_args)
    else
        h = kw_args[:levels]
        levels = Contour.contours(x, y, z, h)
        result = Point2f0[]
        zmin, zmax = get(kw_args, :limits, Vec2f0(extrema(z)))
        cmap = get(kw_args, :color_map, get(kw_args, :color, RGBA{Float32}(0,0,0,1)))
        colors = RGBA{Float32}[]
        for c in levels.contours
            for elem in c.lines
                append!(result, elem.vertices)
                push!(result, Point2f0(NaN32))
                col = GLVisualize.color_lookup(cmap, c.level, zmin, zmax)
                append!(colors, fill(col, length(elem.vertices)+1))
            end
        end
        kw_args[:color] = colors
        kw_args[:color_map] = nothing
        kw_args[:color_norm] = nothing
        return visualize(result, Style(:lines),kw_args)
    end
end


function gl_heatmap(x,y,z, kw_args)
    get!(kw_args, :color_norm, Vec2f0(extrema(z)))
    get!(kw_args, :color_map, Plots.make_gradient(cgrad()))
    delete!(kw_args, :intensity)
    I = GLVisualize.Intensity{1, Float32}
    heatmap = I[z[j,i] for i=1:size(z, 2), j=1:size(z, 1)]
    tex = GLAbstraction.Texture(heatmap, minfilter=:nearest)
    kw_args[:stroke_width] = 0f0
    kw_args[:levels] = 1f0
    visualize(tex, Style(:default), kw_args)
end




function text_plot(text, alignment, kw_args)
    transmat = kw_args[:model]
    obj = visualize(text, Style(:default), kw_args)
    bb = value(GLAbstraction.boundingbox(obj))
    w,h,_ = widths(bb)
    x,y,_ = minimum(bb)
    pivot = origin(alignment)
    pos = pivot - (Point2f0(x, y) .* widths(alignment))
    if kw_args[:rotation] != 0.0
        rot = GLAbstraction.rotationmatrix_z(Float32(font.rotation))
        transmat *= translationmatrix(pivot)*rot*translationmatrix(-pivot)
    end

    transmat *= GLAbstraction.translationmatrix(Vec3f0(pos..., 0))
    GLAbstraction.transformation(obj, transmat)
    view(obj, img.screen, camera=:orthographic_pixel)
end
