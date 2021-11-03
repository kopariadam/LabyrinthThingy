require daslib/media
require daslib/decs_boost
require dasbox
require graphics
require math
require daslib/random
require strings
options debugger            // uncomment for debug in VS Code
require daslib/debug        // uncomment for debug in VS Code

let
    GRID_SIZE: float = 32.0
    PLAYER_SPEED: float = GRID_SIZE * 8.0
    LEVEL_DIM: int = 16
    BULLET_SPEED = GRID_SIZE * 16.0
    PORTAL_THICKNESS = 3.0
    GUN_LENGTH_MUL = 1.5
    LEFT_COLOR = 0xFF0000FF
    RIGHT_COLOR = 0xFFFFFF00
    PORTAL_TRANSITION_TIME = 1.0
    ENABLE_IMAGES = true
    WALK_ANIM_SPEED = 3.0

[decs_template]
struct Wall
    pos: float2
    portalable: bool

struct Level
    size: float2
    dim: int2

var
    seed: int4
    level: Level
    colorPairing: table<uint; uint>
    imgWall0 : Image
    imgWall1 : Image
    imgMan0 : Image
    imgMan1 : Image
    imgMan2 : Image


def draw_looped(pos: float2; width: float; callback: block<(pos: float2): void>)
    let OVERDRAW = 3 //TODO optimize
    for i in range(-OVERDRAW, OVERDRAW)
        for j in range(-OVERDRAW, OVERDRAW)
            let offset = float2(i, j) * level.size
            let newPos = pos + offset
            let screenPos = world_to_screen(newPos)
            if (screenPos.x >= -width * 0.5 && screenPos.y >= -width * 0.5 &&
                screenPos.x <= float(get_screen_width()) + width * 0.5 && screenPos.y <= float(get_screen_height()) + width * 0.5)
                callback |> invoke(newPos)

[decs(stage = draw_walls)]
def draw_walls(wall : Wall)
    let color = wall.portalable ? 0xFFF66619 : 0xFF777777
    let image : Image& = wall.portalable ? imgWall1 : imgWall0
    draw_looped(wall.pos, GRID_SIZE) <| $(pos: float2)
        if ENABLE_IMAGES
            draw_image(image, pos.x - GRID_SIZE * 0.5, pos.y - GRID_SIZE * 0.5)
        else
            fill_rect(pos.x - GRID_SIZE * 0.5, pos.y - GRID_SIZE * 0.5, GRID_SIZE, GRID_SIZE, color)

enum PlayerStates
    NORMAL
    PORTAL_TRANSITION

[decs_template]
struct Player
    pos: float2
    radius: float
    dir: float2
    state : PlayerStates
    portalStart0, portalStart1: float2
    portalEnd0, portalEnd1: float2
    transitionTime: float
    frame: float

def make_player(pos: float2; radius: float)
    create_entity <| @ ( eid, cmp )
        cmp |> set("eid", eid)
        apply_decs_template(cmp, [[Player pos = pos, radius = radius, state = PlayerStates NORMAL, frame = 0.0]])

[decs_template]
struct Bullet
    pos: float2
    radius: float
    speed: float2
    color: uint

def make_bullet(pos, speed: float2; color: uint)
    create_entity <| @ ( eid, cmp )
        cmp |> set("eid", eid)
        apply_decs_template(cmp, [[Bullet pos = pos, speed = speed, color = color, radius = 4.0]])

[decs_template]
struct Portal
    pos: float2
    dir: float2
    color: uint
    timeToNextParticle: float

def make_portal(pos, dir: float2; color: uint)
    create_entity <| @ ( eid, cmp )
        cmp |> set("eid", eid)
        apply_decs_template(cmp, [[Portal pos = pos, dir = dir, color = color]])

def delete_portals(color: uint)
    query() <| $(portal: Portal; eid: EntityId)
        if (portal.color == color)
            delete_entity(eid)

def fix_pos(var pos : float2& implicit)
    pos -= floor(pos / level.size) * level.size

[decs_template]
struct Particle
    pos: float2
    speed: float2
    radius: float
    color: uint
    timeToLive: float

def make_particle(pos, speed: float2; color: uint; radius, time_to_live: float)
    create_entity <| @ ( eid, cmp )
        cmp |> set("eid", eid)
        apply_decs_template(cmp, [[Particle pos = pos, speed = speed, color = color, radius= radius, timeToLive = time_to_live]])

[decs(stage = update)]
def particle_act(var particle: Particle; eid: EntityId)
    particle.timeToLive -= get_delta_time()
    if particle.timeToLive <= 0.0
        delete_entity(eid)
        return
    particle.pos += particle.speed * get_delta_time()
    particle.speed *= exp(log(0.9) * get_delta_time())
    particle.radius *= exp(log(0.8) * get_delta_time())

def circle_bbox_intersects_one(var pos: float2; radius: float; bmin, bmax: float2) : bool
    var dmin = 0.0
    for i in range(2)
        if (pos[i] < bmin[i])
            dmin += sqr(pos[i] - bmin[i])
        elif (pos[i] > bmax[i])
            dmin += sqr(pos[i] - bmax[i])
    return dmin <= sqr(radius)

def circle_bbox_intersects(pos: float2; radius: float; bmin, bmax: float2) : tuple<bool; float2>
    var result : tuple<bool; float2>
    result._0 = false
    result._1 = float2(0,0)
    for i in range(-1, 1+1)
        for j in range(-1, 1+1)
            let resultPos = pos + float2(i,j) * level.size
            if circle_bbox_intersects_one(resultPos, radius, bmin, bmax)
                result._0 = true
                result._1 = resultPos
                return result
    return result

[decs(stage = update)]
def player_act_normal(var player: Player)
    if (player.state != PlayerStates NORMAL)
        return
    player.dir = normalize(get_mouse_position() - world_to_screen(player.pos))
    var moveDir : float2 = float2(0, 0)
    if get_key(VK_W)
        moveDir.y -= 1.0
    if get_key(VK_A)
        moveDir.x -= 1.0
    if get_key(VK_S)
        moveDir.y += 1.0
    if get_key(VK_D)
        moveDir.x += 1.0
    if (dot(moveDir, moveDir) > 0.001)
        player.frame += get_delta_time() * WALK_ANIM_SPEED
    else
        player.frame = 0.0
    moveDir = normalize(moveDir)
    query() <| $(portal : Portal)
        if player.state != PlayerStates NORMAL
            return
        let intersectResult = circle_bbox_intersects(player.pos, player.radius,
                                portal.pos - float2(PORTAL_THICKNESS, PORTAL_THICKNESS),
                                portal.pos + float2(PORTAL_THICKNESS, PORTAL_THICKNESS))
        if (intersectResult._0)
            let dirSum = moveDir + portal.dir
            if dot(dirSum, dirSum) < 0.001
                player.portalStart0 = portal.pos + portal.dir * GRID_SIZE * 0.5
                player.portalStart1 = portal.pos - portal.dir * GRID_SIZE * 0.5
                var foundPair = false
                let targetColor = colorPairing[portal.color]
                query() <| $(other_portal: Portal)
                    if other_portal.color == targetColor
                        foundPair = true
                        player.portalEnd0 = other_portal.pos - other_portal.dir * GRID_SIZE * 0.5
                        player.portalEnd1 = other_portal.pos + other_portal.dir * GRID_SIZE * 0.5
                if foundPair
                    player.state = PlayerStates PORTAL_TRANSITION
                    player.transitionTime = 0.0
    if player.state != PlayerStates NORMAL
        return
    player.pos += get_delta_time() * moveDir * PLAYER_SPEED
    fix_pos(player.pos)
    query() <| $(wall : Wall)
        let intersectResult = circle_bbox_intersects(player.pos, player.radius,
                                wall.pos - float2(GRID_SIZE, GRID_SIZE) * 0.5, wall.pos + float2(GRID_SIZE, GRID_SIZE) * 0.5)
        if (intersectResult._0)
            player.pos = intersectResult._1
            let diff = player.pos - wall.pos
            let absDiff = abs(diff)
            let maxIndex = absDiff.x > absDiff.y ? 0 : 1
            player.pos[maxIndex] = wall.pos[maxIndex] + sign(diff[maxIndex]) * (GRID_SIZE * 0.5 + player.radius)
            fix_pos(player.pos)
    if (get_mouse_button_down(MB_LEFT))
        make_bullet(player.pos + player.dir * player.radius * GUN_LENGTH_MUL, player.dir * BULLET_SPEED, LEFT_COLOR)
    if (get_mouse_button_down(MB_RIGHT))
        make_bullet(player.pos + player.dir * player.radius * GUN_LENGTH_MUL, player.dir * BULLET_SPEED, RIGHT_COLOR)

[decs(stage = update)]
def player_act_portal(var player: Player)
    if (player.state != PlayerStates PORTAL_TRANSITION)
        return
    if (player.transitionTime >= PORTAL_TRANSITION_TIME)
        player.state = PlayerStates NORMAL
        return
    player.frame += get_delta_time() * WALK_ANIM_SPEED
    player.pos = lerp(player.portalStart0, player.portalEnd1, player.transitionTime / PORTAL_TRANSITION_TIME)
    player.transitionTime += get_delta_time()

[decs(stage = update)]
def portal_act(var portal: Portal)
    portal.timeToNextParticle -= get_delta_time()
    if (portal.timeToNextParticle <= 0.0)
        let breadth = float2(portal.dir.y, portal.dir.x) * GRID_SIZE * 0.5
        let emitPos = lerp(portal.pos + breadth, portal.pos - breadth, random_float(seed))
        let emitSpeed = portal.dir * random_float(seed) * 30.0 + breadth * random_float(seed) * 0.25
        make_particle(emitPos, emitSpeed, portal.color, 1.0 + random_float(seed) * 3.0, 1.0 + random_float(seed) * 2.0)
        commit()
        portal.timeToNextParticle = random_float(seed) * 0.5

[decs(stage = update)]
def bullet_act(var bullet: Bullet; eid: EntityId)
    bullet.pos += get_delta_time() * bullet.speed
    fix_pos(bullet.pos)
    var destroy = false
    var makePortal = false
    var portalPos : float2
    var portalDir = float2(0,0)
    query() <| $(wall : Wall)
        if destroy
            return
        let intersectResult = circle_bbox_intersects(bullet.pos, bullet.radius,
                                wall.pos - float2(GRID_SIZE, GRID_SIZE) * 0.5, wall.pos + float2(GRID_SIZE, GRID_SIZE) * 0.5)
        if (intersectResult._0)
            destroy = true
            if wall.portalable
                makePortal = true
                let resultPos = intersectResult._1
                let diff = resultPos - wall.pos
                let absDiff = abs(diff)
                let maxIndex = absDiff.x > absDiff.y ? 0 : 1
                portalPos = wall.pos
                portalPos[maxIndex] += sign(diff[maxIndex]) * (GRID_SIZE * 0.5)
                fix_pos(portalPos)
                portalDir[maxIndex] = sign(diff[maxIndex])
    //TODO player collision
    if destroy
        if makePortal
            delete_portals(bullet.color)
            make_portal(portalPos, portalDir, bullet.color)
        delete_entity(eid)
        commit()


[decs(stage = before_draw)]
def update_level_camera(player: Player)
    setup_2d_camera(player.pos)

def draw_player_one(draw_pos, draw_dir: float2; radius: float; frame: int)
    let gunLength = radius * GUN_LENGTH_MUL
    let color = 0xFFFF0000
    let image : Image& = frame % 2 == 0 ? imgMan0 : frame == 1 ? imgMan1 : imgMan2
    let angle = acos(draw_dir.x) * sign(draw_dir.y)
    draw_looped(draw_pos, gunLength * 2.0) <| $(pos: float2)
        line(pos.x, pos.y, pos.x + gunLength * draw_dir.x, pos.y + gunLength * draw_dir.y, color)
        if ENABLE_IMAGES
            draw_image_transformed(image, pos.x, pos.y, float4(0,0,31,31), 0xFFFFFF, float2(32,32), angle)
        else
            fill_circle(pos.x, pos.y, radius, color)

[decs(stage = draw_gameobj)]
def draw_player(player: Player)
    let frame = int(player.frame) % 4
    if player.state == PlayerStates NORMAL
        draw_player_one(player.pos, player.dir, player.radius, frame)
    if player.state == PlayerStates PORTAL_TRANSITION
        let s = player.transitionTime / PORTAL_TRANSITION_TIME
        draw_player_one(lerp(player.portalStart0, player.portalStart1, s), normalize(player.portalStart1 - player.portalStart0), player.radius, frame)
        draw_player_one(lerp(player.portalEnd0, player.portalEnd1, s), normalize(player.portalEnd1 - player.portalEnd0), player.radius, frame)

[decs(stage = draw_gameobj)]
def draw_bullet(bullet: Bullet)
    draw_looped(bullet.pos, bullet.radius * 2.0) <| $(pos: float2)
        fill_circle(pos.x, pos.y, bullet.radius, bullet.color)

[decs(stage = draw_fx)]
def draw_particle(particle: Particle)
    draw_looped(particle.pos, particle.radius * 2.0) <| $(pos: float2)
        fill_circle(pos.x, pos.y, particle.radius, particle.color)

[decs(stage = draw_fx)]
def draw_portal(portal: Portal)
    var size = abs(portal.dir * PORTAL_THICKNESS + float2(portal.dir.y, portal.dir.x) * GRID_SIZE * 0.5)
    draw_looped(portal.pos, GRID_SIZE) <| $(pos: float2)
        fill_rect(pos.x - size.x, pos.y - size.y, size.x * 2.0, size.y * 2.0, portal.color)

def make_level(dim: int2)
    level.dim = dim
    level.size = float2(dim) * GRID_SIZE

def make_walls()
    let dim = level.dim
    for i in range(dim.x)
        for j in range(dim.y)
            let rand = random_float(seed)
            if  rand > 0.2
                continue
            let pos = GRID_SIZE * (float2(i, j) + float2(0.5, 0.5))
            let portalable = random_float(seed) < 0.5
            create_entity <| @ ( eid, cmp )
                cmp |> set("eid", eid)
                apply_decs_template(cmp, [[Wall pos = pos, portalable = portalable]])

def load_images()
    imgWall0 <- create_image("wall_0.png")
    imgWall1 <- create_image("wall_1.png")
    imgMan0 <- create_image("man_0.png")
    imgMan1 <- create_image("man_1.png")
    imgMan2 <- create_image("man_2.png")

[export]
def initialize(is_hard_reload: bool)
    set_window_title("LabyrinthThingy")
    load_images()
    randomize_seed(seed)
    colorPairing[LEFT_COLOR] = RIGHT_COLOR
    colorPairing[RIGHT_COLOR] = LEFT_COLOR
    make_level(int2(LEVEL_DIM,LEVEL_DIM))
    if is_hard_reload
        make_walls()
        make_player(float2(512, 384), GRID_SIZE / 2.0 - 1.0)
        commit()

[export]
def act
    if get_key(VK_ESCAPE)
        schedule_quit_game()
    decs_stage("update")

[export]
def draw
    decs_stage("before_draw")
    decs_stage("draw_gameobj")
    decs_stage("draw_walls")
    decs_stage("draw_fx")
