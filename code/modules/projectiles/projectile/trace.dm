// Helper proc to check if you can hit them or not.
// Will return a list of hit mobs/objects.
/proc/check_trajectory(atom/target, atom/firer, pass_flags=ATOM_PASS_TABLE|ATOM_PASS_GLASS|ATOM_PASS_GRILLE, atom_flags)
	if(!istype(target) || !istype(firer))
		return 0

	var/obj/item/projectile/test/trace = new /obj/item/projectile/test(get_turf(firer)) //Making the test....

	//Set the flags and pass flags to that of the real projectile...
	if(!isnull(atom_flags))
		trace.atom_flags = atom_flags
	trace.pass_flags = pass_flags

	return trace.launch_projectile(target) //Test it!

/obj/item/projectile/proc/_check_fire(atom/target as mob, var/mob/living/user as mob)  //Checks if you can hit them or not.
	check_trajectory(target, user, pass_flags, atom_flags)

//"Tracing" projectile
/obj/item/projectile/test //Used to see if you can hit them.
	invisibility = 101 //Nope!  Can't see me!
	hitscan = TRUE
	nodamage = TRUE
	damage = 0
	var/list/hit = list()

/obj/item/projectile/test/process_hitscan()
	. = ..()
	if(!QDELING(src))
		qdel(src)
	return hit

/obj/item/projectile/test/Bump(atom/A)
	if(A != src)
		hit |= A
	return ..()

/obj/item/projectile/test/attack_mob()
	return
