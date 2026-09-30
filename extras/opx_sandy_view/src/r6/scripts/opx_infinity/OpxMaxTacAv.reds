// OPX Infinity -- the MaxTac AV in its visible livery, on every player's
// machine. opx_sandy_view 1.4.10.
//
// WHY IT WAS INVISIBLE. Every TweakDB record of the MaxTac AV --
// `Vehicle.max_tac_av`, the one opx_infinity's MaxTac insertion and the
// division's garage bring out, and `max_tac_av1`-`3` and
// `max_tac_av_2nd_wave1`-`3` -- names the appearance
// `zetatech_surveyor__basic_maxtac_camo_01` (read out of the game's own
// `tweakdb_ep1.bin`), and it is also the default of their template,
// `base\dependencies\vehicles\special\av_zetatech_surveyor_basic_01_ep1.ent`.
// That appearance draws the body, the three doors, the four engines, the
// missile launchers and the interior with the mesh appearance `maxtac_cloak`:
// the optical camo. The base game only ever lifts it through the prevention
// AI's own behaviour (`TurnOffPsychoSquadAvCammo` starts the effect
// `cloak_off`); a vehicle Open77 spawns runs no such AI, and one created
// without an appearance comes out in its record's -- so the AV stayed cloaked
// on every machine: the stickers, one door, the thrusters and the lights were
// all anyone saw (reported 2026-09-28).
//
// 1.4.11: opx_infinity now CREATES the division's AV in the visible livery
// (the job fleet's row, and the insertion's `MAXTAC.AV.APPEARANCE`): the
// platform applies a create's appearance on every client since its 2026-09-14
// build. This script stays as the second line, for a MaxTac hull created
// without one (a hangar's stock, a staff spawn) and for a client whose platform
// predates that build.
//
// WHAT THIS DOES. The same template's own visible MaxTac livery,
// `zetatech_surveyor__basic_ep1_maxtac_01` (its `.app`'s `maxtac_01`: the
// body in `arasaka_01` under the MaxTac stickers, the cabin and its seats), is
// scheduled on a vehicle whose record names the cloaked one, the moment the
// game attaches it -- on every machine the AV is streamed to, since each draws
// its own copy -- and a short watch reads the result back, schedules it again
// if the cloak comes back, and says so once in the Open77 client log. Only in
// a multiplayer session: single player keeps the base game's cloaked arrival.
// The record itself stays `Vehicle.max_tac_av`, because the platform flies
// only `Vehicle.av_*` and that one record as an AV.

public static func OpxMaxTacAvCloaked() -> CName {
  return n"zetatech_surveyor__basic_maxtac_camo_01";
}

public static func OpxMaxTacAvVisible() -> CName {
  return n"zetatech_surveyor__basic_ep1_maxtac_01";
}

@wrapMethod(VehicleObject)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  OpxMaxTacAvLivery(this);
  return result;
}

// `tries`: steps left to watch (every half second); `asked`: how many times the
// visible livery was scheduled; `said`: the log line already written.
public class OpxMaxTacAvTick extends DelayCallback {
  public let vehicle: wref<VehicleObject>;
  public let game: GameInstance;
  public let tries: Int32;
  public let asked: Int32;
  public let said: Bool;

  public func Call() -> Void {
    OpxMaxTacAvStep(this);
  }
}

public static func OpxMaxTacAvLivery(vehicle: ref<VehicleObject>) -> Void {
  if !IsDefined(vehicle) || !Open77MultiplayerPolicyActive() {
    return;
  };
  let record: wref<Vehicle_Record> = vehicle.GetRecord();
  if !IsDefined(record) || NotEquals(record.AppearanceName(), OpxMaxTacAvCloaked()) {
    return;
  };
  let tick: ref<OpxMaxTacAvTick> = new OpxMaxTacAvTick();
  tick.vehicle = vehicle;
  tick.game = vehicle.GetGame();
  tick.tries = 20;
  if NotEquals(vehicle.GetCurrentAppearanceName(), OpxMaxTacAvVisible()) {
    vehicle.ScheduleAppearanceChange(OpxMaxTacAvVisible());
    tick.asked = 1;
  };
  GameInstance.GetDelaySystem(tick.game).DelayCallback(tick, 0.5, false);
}

public static func OpxMaxTacAvStep(tick: ref<OpxMaxTacAvTick>) -> Void {
  let vehicle: ref<VehicleObject> = tick.vehicle;
  // Gone, or detached: this watch ends here (an attach starts a new one).
  if !IsDefined(vehicle) || !vehicle.IsAttached() {
    return;
  };
  let now: CName = vehicle.GetCurrentAppearanceName();
  let who: String = "opx_sandy_view maxtac av: " + EntityID.ToDebugString(vehicle.GetEntityID());
  if Equals(now, OpxMaxTacAvVisible()) {
    if !tick.said {
      tick.said = true;
      Open77PlayerResetTrace(who + " drawn in the visible livery " + NameToString(now)
        + " (its record names the cloaked " + NameToString(OpxMaxTacAvCloaked()) + "; asked "
        + IntToString(tick.asked) + " time(s))");
    };
  } else {
    if Equals(now, OpxMaxTacAvCloaked()) && tick.asked < 3 {
      vehicle.ScheduleAppearanceChange(OpxMaxTacAvVisible());
      tick.asked += 1;
    };
  };
  tick.tries -= 1;
  if tick.tries <= 0 {
    if !tick.said {
      Open77PlayerResetTrace(who + " is still in " + NameToString(now) + " after "
        + IntToString(tick.asked) + " request(s) for " + NameToString(OpxMaxTacAvVisible()));
    };
    return;
  };
  let next: ref<OpxMaxTacAvTick> = new OpxMaxTacAvTick();
  next.vehicle = tick.vehicle;
  next.game = tick.game;
  next.tries = tick.tries;
  next.asked = tick.asked;
  next.said = tick.said;
  GameInstance.GetDelaySystem(tick.game).DelayCallback(next, 0.5, false);
}
