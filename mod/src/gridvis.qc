/*
================================================================
gridvis test mod

Spawns thousands of idle monsters over the test field and flies a
scripted top-down camera over them, twice: first at normal zoom,
then at a far zoom. Run it on gridtest_vis (normal vis) and on
gridtest_grid (gridvis) to compare.

The player entity is the camera: QuakeC moves a focus point along
a fixed path on the ground and puts the player above and behind it,
looking down at it. The client renders from the player's origin.
The player's view_ofs points from the camera to the focus in XY, so
the server takes the PVS at the focus (origin + view_ofs) and sends
the monsters around it. The client only uses view_ofs_z (0 here).

Cvars (read at map start):
  scratch1  number of monsters (0 = 4000)
  scratch2  1 = makestatic monsters (client-side culling only)
  scratch3  1 = bench mode: "disconnect; quit" at the end, so a
            recorded demo ends the timedemo and quits
  scratch4  1 = take screenshots at fixed points of the run
================================================================
*/

.float gv_size;       // worldspawn key: half size of the field (set by tools/makemap.py)
.entity gv_next;      // list of monsters, for counting

float GV_DEFAULT_COUNT = 4000;

// camera: looks down at the focus at this pitch, from this distance (along the view)
float GV_PITCH = 55;
float GV_NEAR_DIST = 600;
float GV_FAR_DIST = 3200;   // camera 2620 high, 1835 behind the focus: under the 3072 sky

float GV_SPEED = 800;       // units per second along the path
float GV_WAIT = 1.5;        // seconds before the run starts
float GV_ZOOMTIME = 3;      // seconds to zoom out between passes
float GV_COUNT_INTERVAL = 0.25;

// run states
float GV_WAITING = 0;
float GV_PASS_NEAR = 1;
float GV_ZOOMING = 2;
float GV_PASS_FAR = 3;
float GV_DONE = 4;

float gv_total;         // monsters spawned
float gv_static;        // monsters are static entities
float gv_bench;
entity gv_first;

float gv_state;
float gv_statetime;
float gv_dist;          // distance travelled along the path in this pass
float gv_nextcount;
float gv_sent;          // monsters in the player's PVS at the last count

float gv_camdist;       // current camera distance to the focus
float gv_shots;         // screenshots taken (scratch4)
float gv_shoot;
float gv_cfgsent;       // client settings sent

// per pass statistics
float gv_samples, gv_sum, gv_min, gv_max;

// centerprint with several strings (the engine concatenates them)
void(entity client, ...) gv_centerprint = #73;
void(...) gv_bprint = #23;

void() SUB_Null = { };
void() info_player_start = { };

//----------------------------------------------------------------
// Path: a "U" over the field, as fractions of its half size
//----------------------------------------------------------------
float GV_NUMPOINTS = 4;

vector(float i) gv_pathpoint =
{
	local vector v;
	local float s;

	s = world.gv_size;
	if (i == 0)
		v = '-0.75 -0.5 0';
	else if (i == 1)
		v = '0.75 -0.5 0';
	else if (i == 2)
		v = '0.75 0.5 0';
	else
		v = '-0.75 0.5 0';

	v = v * s;
	v_z = 0;    // the focus is on the ground
	return v;
};

float() gv_pathlength =
{
	local float i, len;

	len = 0;
	for (i = 0; i < GV_NUMPOINTS - 1; i++)
		len = len + vlen (gv_pathpoint (i + 1) - gv_pathpoint (i));
	return len;
};

// position at distance d along the path (reverse = from the end)
vector(float d, float reverse) gv_pathpos =
{
	local float i, seglen;
	local vector a, b;

	if (reverse)
		d = gv_pathlength () - d;

	for (i = 0; i < GV_NUMPOINTS - 1; i++)
	{
		a = gv_pathpoint (i);
		b = gv_pathpoint (i + 1);
		seglen = vlen (b - a);
		if (d <= seglen)
			return a + (b - a) * (d / seglen);
		d = d - seglen;
	}
	return gv_pathpoint (GV_NUMPOINTS - 1);
};

//----------------------------------------------------------------
// Monsters
//----------------------------------------------------------------
string(float i) gv_monstermodel =
{
	i = floor (i * 6);
	if (i == 0) return "progs/soldier.mdl";
	if (i == 1) return "progs/dog.mdl";
	if (i == 2) return "progs/knight.mdl";
	if (i == 3) return "progs/ogre.mdl";
	if (i == 4) return "progs/zombie.mdl";
	return "progs/demon.mdl";
};

void() gv_spawn_monsters =
{
	local float n, side, i, j, spacing, limit;
	local entity m, last;
	local vector org;

	n = cvar ("scratch1");
	if (n <= 0)
		n = GV_DEFAULT_COUNT;
	gv_static = cvar ("scratch2") == 1;

	if (!world.gv_size)
		world.gv_size = 4000;

	// a jittered square grid over the field, away from the walls
	limit = world.gv_size - 128;
	side = 1;
	while (side * side < n)
		side = side + 1;
	spacing = 2 * limit / side;

	gv_total = 0;
	last = world;
	for (j = 0; j < side && gv_total < n; j++)
	{
		for (i = 0; i < side && gv_total < n; i++)
		{
			org_x = -limit + (i + 0.5 + (random () - 0.5) * 0.6) * spacing;
			org_y = -limit + (j + 0.5 + (random () - 0.5) * 0.6) * spacing;
			org_z = 24;

			m = spawn ();
			m.classname = "gv_monster";
			m.solid = SOLID_NOT;
			m.movetype = MOVETYPE_NONE;
			setmodel (m, gv_monstermodel (random ()));
			setsize (m, '-16 -16 -24', '16 16 40');
			m.angles_y = random () * 360;
			setorigin (m, org);
			gv_total = gv_total + 1;

			if (gv_static)
			{
				makestatic (m);
				continue;
			}

			if (last)
				last.gv_next = m;
			else
				gv_first = m;
			last = m;
		}
	}

	bprint ("gridvis: spawned ");
	bprint (ftos (gv_total));
	if (gv_static)
		bprint (" static");
	bprint (" monsters\n");
};

// how many monsters are in the player's PVS (what the server sends)
float() gv_count_sent =
{
	local entity m, oself;
	local float n;

	// checkclient() is true when self's leaf is in the PVS of the checked client
	oself = self;
	n = 0;
	for (m = gv_first; m; m = m.gv_next)
	{
		self = m;
		if (checkclient ())
			n = n + 1;
	}
	self = oself;
	return n;
};

//----------------------------------------------------------------
// worldspawn
//----------------------------------------------------------------
void() worldspawn =
{
	precache_model ("progs/player.mdl");    // the engine requires it, even if the player has no model
	precache_model ("progs/soldier.mdl");
	precache_model ("progs/dog.mdl");
	precache_model ("progs/knight.mdl");
	precache_model ("progs/ogre.mdl");
	precache_model ("progs/zombie.mdl");
	precache_model ("progs/demon.mdl");

	lightstyle (0, "m");

	gv_bench = cvar ("scratch3") == 1;
	gv_state = GV_WAITING;
	gv_statetime = 0;

	gv_spawn_monsters ();
};

//----------------------------------------------------------------
// Run
//----------------------------------------------------------------
// puts the camera (the player) above and behind the focus, looking at it,
// and points the server's PVS at the focus
void(vector focus) gv_place =
{
	local vector ang, cam;

	ang = '0 90 0';         // fixed yaw: +Y is up on screen
	ang_x = GV_PITCH;
	makevectors (ang);
	cam = focus - v_forward * gv_camdist;

	setorigin (self, cam);
	self.view_ofs = focus - cam;
	self.view_ofs_z = 0;    // the client only uses this one: eye at the origin

	self.angles = ang;
	self.fixangle = TRUE;
};

// scratch4 1: once when cond becomes true, in order: a screenshot, the camera position
// (server and client), and a network sample: cl_shownet 2 for a couple of frames, so the
// client logs every entity update it receives (tools/netcheck.py counts them)
void(float n, float cond) gv_screenshot =
{
	if (!gv_shoot || gv_shots != n || !cond)
		return;
	stuffcmd (self, "screenshot; viewpos; cl_shownet 2; wait; wait; cl_shownet 0\n");
	gv_bprint ("gridvis: camera ", vtos (self.origin), " angles ", vtos (self.angles), " pvs ", vtos (self.origin + self.view_ofs), "\n");
	gv_bprint ("gridvis: sample ", ftos (n), " map=", mapname, " checkclient=", ftos (gv_count_sent ()), "\n");
	gv_shots = gv_shots + 1;
};

string() gv_passname =
{
	if (gv_state == GV_PASS_FAR || gv_state == GV_ZOOMING)
		return "far";
	return "normal";
};

void() gv_resetstats =
{
	gv_samples = 0;
	gv_sum = 0;
	gv_min = 999999;
	gv_max = 0;
};

// one line per pass in the console (bench.py reads these)
void() gv_printstats =
{
	if (gv_static || !gv_samples)
		return;
	bprint ("GRIDVIS map=");
	bprint (mapname);
	bprint (" pass=");
	bprint (gv_passname ());
	bprint (" total=");
	bprint (ftos (gv_total));
	bprint (" avg=");
	bprint (ftos (rint (gv_sum / gv_samples)));
	bprint (" min=");
	bprint (ftos (gv_min));
	bprint (" max=");
	bprint (ftos (gv_max));
	bprint ("\n");
};

void() gv_showstatus =
{
	local string s;

	if (gv_state == GV_WAITING)
		s = "   starting";
	else if (gv_state == GV_PASS_NEAR)
		s = "   pass 1: normal zoom";
	else if (gv_state == GV_ZOOMING)
		s = "   zooming out";
	else if (gv_state == GV_PASS_FAR)
		s = "   pass 2: far zoom";
	else
		s = "   done";

	// more than 4 lines: the engine draws the centerprint near the top of the screen
	if (gv_static)
		gv_centerprint (self, mapname, s, "\nstatic monsters (culled by the client)\n\n\n\n\n\n\n\n\n\n");
	else
		gv_centerprint (self, mapname, s, "\nmonsters sent: ", ftos (gv_sent), " / ", ftos (gv_total), "\n\n\n\n\n\n\n\n\n\n");
};

void() gv_setstate =
{
	gv_state = gv_state + 1;
	gv_statetime = time;
	gv_dist = 0;
};

void() gv_run =
{
	local float t, f, len;

	t = time - gv_statetime;
	len = gv_pathlength ();

	if (gv_state == GV_WAITING)
	{
		// client settings, once the client is in the game (a stuffcmd from
		// PutClientInServer is lost during the connection).
		// r_novis 1: the client draws the whole floor. At the far zoom the camera is far
		// from the focus, and the client's PVS (taken at the camera) would cut the floor.
		// The monsters are still culled by the server, around the focus.
		if (!gv_cfgsent)
		{
			stuffcmd (self, "chase_active 0; crosshair 0; r_drawviewmodel 0; viewsize 120; fov 90; scr_showfps 1; r_novis 1\n");
			gv_cfgsent = TRUE;
		}
		gv_camdist = GV_NEAR_DIST;
		gv_place (gv_pathpos (0, FALSE));
		gv_screenshot (0, t >= 1);
		if (t >= GV_WAIT)
		{
			gv_setstate ();
			gv_resetstats ();
		}
	}
	else if (gv_state == GV_PASS_NEAR)
	{
		gv_dist = gv_dist + GV_SPEED * frametime;
		gv_place (gv_pathpos (gv_dist, FALSE));
		gv_screenshot (1, gv_dist >= len * 0.4);
		if (gv_dist >= len)
		{
			gv_printstats ();
			gv_setstate ();
		}
	}
	else if (gv_state == GV_ZOOMING)
	{
		// zoom out in place at the end of the path
		f = t / GV_ZOOMTIME;
		if (f > 1)
			f = 1;
		f = f * f * (3 - 2 * f);
		gv_camdist = GV_NEAR_DIST + (GV_FAR_DIST - GV_NEAR_DIST) * f;
		gv_place (gv_pathpos (len, FALSE));
		if (t >= GV_ZOOMTIME)
		{
			gv_setstate ();
			gv_resetstats ();
		}
	}
	else if (gv_state == GV_PASS_FAR)
	{
		// same path, backwards
		gv_dist = gv_dist + GV_SPEED * frametime;
		gv_place (gv_pathpos (gv_dist, TRUE));
		gv_screenshot (2, gv_dist >= len * 0.1);
		gv_screenshot (3, gv_dist >= len * 0.5);
		if (gv_dist >= len)
		{
			gv_printstats ();
			gv_setstate ();
			if (gv_bench)
				stuffcmd (self, "disconnect; quit\n");
		}
	}
	else
		gv_place (gv_pathpos (0, FALSE));

	if (time >= gv_nextcount)
	{
		gv_nextcount = time + GV_COUNT_INTERVAL;
		if (!gv_static)
		{
			gv_sent = gv_count_sent ();
			if (gv_state == GV_PASS_NEAR || gv_state == GV_PASS_FAR)
			{
				gv_samples = gv_samples + 1;
				gv_sum = gv_sum + gv_sent;
				if (gv_sent < gv_min)
					gv_min = gv_sent;
				if (gv_sent > gv_max)
					gv_max = gv_sent;
			}
		}
		gv_showstatus ();
	}
};

//----------------------------------------------------------------
// Engine entry points
//----------------------------------------------------------------
void() main = { };
void() StartFrame = { };
void() SetNewParms = { };
void() SetChangeParms = { };
void() ClientKill = { };
void() ClientConnect = { };
void() ClientDisconnect = { };
void() PlayerPostThink = { };

void() PutClientInServer =
{
	self.classname = "player";
	self.health = 100;          // checkclient() ignores dead clients
	self.takedamage = DAMAGE_NO;
	self.solid = SOLID_NOT;
	self.movetype = MOVETYPE_NONE;
	self.flags = FL_CLIENT;
	// the client only moves entities that have a model, and it renders from this one.
	// It doesn't draw its own entity in first person, so the model is never seen.
	// (Don't make it invisible with alpha: the server doesn't send alpha 0 entities.)
	setmodel (self, "progs/player.mdl");
	setsize (self, '0 0 0', '0 0 0');
	gv_camdist = GV_NEAR_DIST;
	gv_place (gv_pathpos (0, FALSE));

	gv_shoot = cvar ("scratch4") == 1;
	gv_shots = 0;
	gv_cfgsent = FALSE;
	gv_statetime = time;
	gv_nextcount = time;
};

void() PlayerPreThink =
{
	gv_run ();
};
