//
// SSshuttle subsystem - Handles initialization and processing of shuttles.
//
// Also handles initialization and processing of overmap sectors.	// For... some reason...
//

SUBSYSTEM_DEF(shuttle)
	name = "Shuttles"
	wait = 2 SECONDS
	priority = FIRE_PRIORITY_SHUTTLES
	init_order = INIT_ORDER_SHUTTLES
	subsystem_flags = SS_KEEP_TIMING|SS_NO_TICK_CHECK
	runlevels = RUNLEVEL_GAME|RUNLEVEL_POSTGAME

	/// Whether ships can move on the overmap; used for adminbus.
	var/overmap_halted = FALSE
	/// List of all ships.
	var/list/ships = list()

	/// Maps shuttle tags to shuttle datums, so that they can be looked up.
	var/list/shuttles = list()
	/// Simple list of shuttles, for processing
	var/list/process_shuttles = list()

	/// Maps shuttle landmark tags to instances
	var/list/registered_shuttle_landmarks = list()
	/// world.time of most recent addition to registered_shuttle_landmarks
	var/last_landmark_registration_time
	/// (Not Implemented) Keeps records of shuttle movement, format is list(datum/shuttle = datum/shuttle_log)
	var/list/shuttle_logs = list()
	/// All the areas of all shuttles.
	var/list/shuttle_areas = list()
	/// Docking controller tag -> docking controller program, mostly for init purposes.
	var/list/docking_registry = list()

	/// Stores automatic landmarks that are waiting for a sector to finish loading.
	var/list/landmarks_awaiting_sector = list()
	/// Stores landmark_tags that need to be assigned to the sector (landmark_tag = sector) when registered.
	var/list/landmarks_still_needed = list()
	/// A queue for shuttles to initialize at the appropriate time.
	var/list/shuttles_to_initialize
	/// Used to find all sector objects at the appropriate time.
	var/list/sectors_to_initialize
	/// Block initialization of new shuttles/sectors
	var/block_init_queue = TRUE

	/// Shuttles remaining to process this fire() tick
	var/tmp/list/current_run


	/**
	 *! I made these shitty vars so we don't search for these in GOD DAMN WORLD
	 *! If I find these are still here in 2023 I'll be very upset.
	 * @Zandario
	 */

	var/list/unary_engines = list()
	var/list/ion_engines = list()

/datum/controller/subsystem/shuttle/Initialize(timeofday)
	last_landmark_registration_time = world.time
	// Find all declared shuttle datums and initailize them. (Okay, queue them for initialization a few lines further down)
	for(var/shuttle_type in subtypesof(/datum/shuttle)) // This accounts for most shuttles, though away maps can queue up more.
		var/datum/shuttle/shuttle = shuttle_type
		if(initial(shuttle.category) == shuttle_type)
			continue // Its an "abstract class" datum, not for a real shuttle.
		if(!initial(shuttle.defer_initialisation)) // Skip if it asks not to be initialized at startup.
			LAZYDISTINCTADD(shuttles_to_initialize, shuttle_type)
	block_init_queue = FALSE
	process_init_queues()
	return ..()

/datum/controller/subsystem/shuttle/fire(resumed = 0)
	if (!resumed)
		src.current_run = process_shuttles.Copy()

	var/list/working_shuttles = src.current_run	// Cache for sanic speed
	while(working_shuttles.len)
		var/datum/shuttle/S = working_shuttles[working_shuttles.len]
		working_shuttles.len--
		if(!istype(S) || QDELETED(S))
			log_debug(SPAN_DEBUG("Bad entry in SSshuttle.process_shuttles - [log_info_line(S)] "))
			process_shuttles -= S
			continue
		// NOTE - In old system, /datum/shuttle/ferry was processed only if (F.process_state || F.always_process)
		if(S.process_state && (S.process(wait, times_fired, src) == PROCESS_KILL))
			process_shuttles -= S

		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/shuttle/proc/process_init_queues()
	if(block_init_queue)
		return
	initialize_shuttles()
	initialize_sectors()

// Initializes all shuttles in shuttles_to_initialize
/datum/controller/subsystem/shuttle/proc/initialize_shuttles()
	var/list/shuttles_made = list()
	for(var/shuttle_type in shuttles_to_initialize)
		var/shuttle = initialize_shuttle(shuttle_type)
		if(shuttle)
			shuttles_made += shuttle
	hook_up_motherships(shuttles_made)
	hook_up_shuttle_objects(shuttles_made)
	shuttles_to_initialize = null
	//! citadel edit - initialize overmaps shuttles here until we rewrite overmaps to not be a dumpster fire god damnit
	for(var/obj/machinery/atmospherics/component/unary/engine/E in unary_engines)
		if(E.linked)
			continue
		E.link_to_ship()
	for(var/obj/machinery/ion_engine/E in ion_engines)
		if(E.linked)
			continue
		E.link_to_ship()

/datum/controller/subsystem/shuttle/proc/initialize_sectors()
	for(var/sector in sectors_to_initialize)
		initialize_sector(sector)
	sectors_to_initialize = null

/datum/controller/subsystem/shuttle/proc/register_landmark(shuttle_landmark_tag, obj/effect/shuttle_landmark/shuttle_landmark)
	if (registered_shuttle_landmarks[shuttle_landmark_tag])
		CRASH("Attempted to register shuttle landmark with tag [shuttle_landmark_tag], but it is already registered!")
	if (istype(shuttle_landmark))
		registered_shuttle_landmarks[shuttle_landmark_tag] = shuttle_landmark
		last_landmark_registration_time = world.time

		var/obj/effect/overmap/visitable/O = landmarks_still_needed[shuttle_landmark_tag]
		if(O)	// These need to be added to sectors, which we handle.
			try_add_landmark_tag(shuttle_landmark_tag, O)
			landmarks_still_needed -= shuttle_landmark_tag
		else if(istype(shuttle_landmark, /obj/effect/shuttle_landmark/automatic))	// These find their sector automatically
			O = map_sectors["[shuttle_landmark.z]"]
			O ? O.add_landmark(shuttle_landmark, shuttle_landmark.shuttle_restricted) : (landmarks_awaiting_sector += shuttle_landmark)

/datum/controller/subsystem/shuttle/proc/get_landmark(var/shuttle_landmark_tag)
	return registered_shuttle_landmarks[shuttle_landmark_tag]

// Checks if the given sector's landmarks have initialized; if so, registers them with the sector, if not, marks them for assignment after they come in.
// Also adds automatic landmarks that were waiting on their sector to spawn.
/datum/controller/subsystem/shuttle/proc/initialize_sector(obj/effect/overmap/visitable/given_sector)
	given_sector.populate_sector_objects()	// This is a late init operation that sets up the sector's map_z and does non-overmap-related init tasks.

	for(var/landmark_tag in given_sector.initial_generic_waypoints)
		if(!try_add_landmark_tag(landmark_tag, given_sector))
			landmarks_still_needed[landmark_tag] = given_sector	// Landmark isn't registered yet, queue it to be added once it is.

	for(var/shuttle_name in given_sector.initial_restricted_waypoints)
		for(var/landmark_tag in given_sector.initial_restricted_waypoints[shuttle_name])
			if(!try_add_landmark_tag(landmark_tag, given_sector))
				landmarks_still_needed[landmark_tag] = given_sector	// Landmark isn't registered yet, queue it to be added once it is.

	var/landmarks_to_check = landmarks_awaiting_sector.Copy()
	for(var/thing in landmarks_to_check)
		var/obj/effect/shuttle_landmark/automatic/landmark = thing
		if(landmark.z in given_sector.map_z)
			given_sector.add_landmark(landmark, landmark.shuttle_restricted)
			landmarks_awaiting_sector -= landmark

// Attempts to add a landmark instance with a sector (returns false if landmark isn't registered yet)
/datum/controller/subsystem/shuttle/proc/try_add_landmark_tag(landmark_tag, obj/effect/overmap/visitable/given_sector)
	var/obj/effect/shuttle_landmark/landmark = get_landmark(landmark_tag)
	if(!landmark)
		return

	if(landmark.landmark_tag in given_sector.initial_generic_waypoints)
		given_sector.add_landmark(landmark)
		. = 1
	for(var/shuttle_name in given_sector.initial_restricted_waypoints)
		if(landmark.landmark_tag in given_sector.initial_restricted_waypoints[shuttle_name])
			given_sector.add_landmark(landmark, shuttle_name)
			. = 1

/datum/controller/subsystem/shuttle/proc/initialize_shuttle(var/shuttle_type)
	var/datum/shuttle/shuttle = shuttle_type
	if(initial(shuttle.category) != shuttle_type)	// Skip if its an "abstract class" datum
		shuttle = new shuttle()
		shuttle_areas |= shuttle.shuttle_area
		log_debug(SPAN_DEBUG("Initialized shuttle [shuttle] ([shuttle.type])"))
		return shuttle
		// Historical note:  No need to call shuttle.init_docking_controllers(), controllers register themselves
		// and shuttles fetch refs in New().  Shuttles also dock() themselves in new if they want.

// TODO - Leshana to hook up more of this when overmap is ported.
/datum/controller/subsystem/shuttle/proc/hook_up_motherships(shuttles_list)
	for(var/datum/shuttle/S in shuttles_list)
		if(S.mothershuttle && !S.motherdock)
			var/datum/shuttle/mothership = shuttles[S.mothershuttle]
			if(mothership)
				S.motherdock = S.current_location.landmark_tag
				mothership.shuttle_area |= S.shuttle_area
			else
				log_debug(SPAN_DEBUG("Shuttle [S] was unable to find mothership [mothership]!"))

// Let shuttles scan their owned areas for objects they want to configure (Called after mothership hookup)
/datum/controller/subsystem/shuttle/proc/hook_up_shuttle_objects(shuttles_list)
	for(var/datum/shuttle/S in shuttles_list)
		S.populate_shuttle_objects()

// Admin command to halt/resume overmap
/datum/controller/subsystem/shuttle/proc/toggle_overmap(new_setting)
	if(overmap_halted == new_setting)
		return
	overmap_halted = !overmap_halted
	for(var/ship in ships)
		var/obj/effect/overmap/visitable/ship/ship_effect = ship
		overmap_halted ? ship_effect.halt() : ship_effect.unhalt()

/datum/controller/subsystem/shuttle/stat_entry()
	..("Shuttles:[process_shuttles.len]/[shuttles.len], Ships:[ships.len], L:[registered_shuttle_landmarks.len][overmap_halted ? ", HALT" : ""]")
