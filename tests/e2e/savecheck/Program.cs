// savecheck: read Gen 1/Gen 2 cartridge saves with PKHeX.Core and check a trade.
// A Gen 1 <-> Gen 2 trade (the Time Capsule) is checked against PKHeX's own
// conversion (PK1.ConvertToPK2 / PK2.ConvertToPK1): held item <-> catch rate.
//
//   savecheck show <file.sav>...                 trainer, party, boxes, legality
//   savecheck trade <mine_before.sav> <mine_after.sav> <theirs_before.sav>
//       what left my party, what arrived, and whether the arrival is the
//       other player's mon with its trainer, DVs, stat exp, EXP, moves and
//       nickname intact (species may differ only by a trade evolution)
//   savecheck trades <mine_before.sav> <mine_after.sav> <theirs_before.sav> <rounds>
//       several trades in a row, Gen 2 rules: <rounds> is "m/t,m/t,..", the
//       1-based party slots each side gave in each round.  Both parties are
//       replayed the way the cart files a trade (the given mon leaves, the
//       rest close up, the arrival goes on the end and trade-evolves there:
//       Everstone blocks, a required item is consumed), and every slot of
//       mine_after is checked against that replay
//
// Exit code 0 when every check passes, 1 otherwise.
using PKHeX.Core;

static class Program
{
    static int failures;

    static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "show")
        {
            foreach (var path in args.Skip(1)) Show(path);
            return failures == 0 ? 0 : 1;
        }
        if (args.Length == 4 && args[0] == "trade")
            return Trade(args[1], args[2], args[3]);
        if (args.Length == 5 && args[0] == "trades")
            return Trades(args[1], args[2], args[3], args[4]);
        Console.Error.WriteLine("usage: savecheck show <file.sav>...");
        Console.Error.WriteLine("       savecheck trade <mine_before.sav> <mine_after.sav> <theirs_before.sav>");
        Console.Error.WriteLine("       savecheck trades <mine_before.sav> <mine_after.sav> <theirs_before.sav> <m/t,m/t,...>");
        return 2;
    }

    static SaveFile Load(string path)
    {
        // PKHeX's own detection, the same as opening the file in PKHeX
        if (!SaveUtil.TryGetSaveFile(path, out var sav) || sav is not (SAV1 or SAV2))
            throw new InvalidDataException($"{path}: PKHeX does not recognize this as a Gen 1 or Gen 2 save");
        if (!sav.ChecksumsValid) Fail($"{path}: checksums are not valid");
        return sav;
    }

    static List<GBPKM> Party(SaveFile sav)
    {
        var list = new List<GBPKM>();
        for (int i = 0; i < sav.PartyCount; i++) list.Add((GBPKM)sav.GetPartySlotAtIndex(i));
        return list;
    }

    static List<(int box, int slot, GBPKM pk)> Boxed(SaveFile sav)
    {
        var list = new List<(int, int, GBPKM)>();
        for (int b = 0; b < sav.BoxCount; b++)
            for (int s = 0; s < sav.BoxSlotCount; s++)
            {
                var pk = (GBPKM)sav.GetBoxSlotAtIndex(b, s);
                if (pk.Species != 0) list.Add((b + 1, s + 1, pk));
            }
        return list;
    }

    static string Name(ushort species) => GameInfo.Strings.specieslist[species];
    static string MoveName(ushort move) => GameInfo.Strings.movelist[move];

    // Gen 1 DVs, unpacked from the cartridge's two bytes: attack, defense,
    // speed, special, and HP from their low bits.
    static string Dvs(GBPKM pk)
    {
        int d = pk.DV16;
        int atk = (d >> 12) & 15, def = (d >> 8) & 15, spe = (d >> 4) & 15, spc = d & 15;
        int hp = ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1);
        return $"{hp}/{atk}/{def}/{spe}/{spc}";
    }

    static string StatExp(GBPKM pk) => $"{pk.EV_HP}/{pk.EV_ATK}/{pk.EV_DEF}/{pk.EV_SPE}/{pk.EV_SPC}";

    static string Moves(GBPKM pk)
    {
        var parts = new List<string>();
        ushort[] moves = [pk.Move1, pk.Move2, pk.Move3, pk.Move4];
        int[] pp = [pk.Move1_PP, pk.Move2_PP, pk.Move3_PP, pk.Move4_PP];
        for (int i = 0; i < 4; i++) if (moves[i] != 0) parts.Add($"{MoveName(moves[i])} {pp[i]}");
        return string.Join(", ", parts);
    }

    static string Legality(GBPKM pk)
    {
        var la = new LegalityAnalysis(pk);
        return la.Valid ? "legal" : "NOT LEGAL: " + la.Report().Replace(Environment.NewLine, " | ");
    }

    // Gen 1 keeps a catch-rate byte where Gen 2 keeps the held item
    static string ItemOrCatch(GBPKM pk) => pk is PK1 p1 ? $"catch {p1.CatchRate}" : $"item 0x{pk.HeldItem:X2}";

    // what the Time Capsule should turn src into on the other generation
    static GBPKM ConvertFor(GBPKM src, GBPKM target) => (src, target) switch
    {
        (PK1 a, PK2) => a.ConvertToPK2(),
        (PK2 b, PK1) => b.ConvertToPK1(),
        _ => src,
    };

    static string Describe(GBPKM pk)
    {
        var nick = pk.IsNicknamed ? $" \"{pk.Nickname}\"" : "";
        return $"{Name(pk.Species)}{nick} L{pk.CurrentLevel}  OT {pk.OriginalTrainerName}/{pk.TID16:D5}"
             + $"  DVs {Dvs(pk)}  statexp {StatExp(pk)}  exp {pk.EXP}  {ItemOrCatch(pk)}"
             + $"\n        HP {pk.Stat_HPCurrent}/{pk.Stat_HPMax} atk {pk.Stat_ATK} def {pk.Stat_DEF}"
             + $" spe {pk.Stat_SPE} {(pk is PK1 ? $"spc {pk.Stat_SPA}" : $"spa {pk.Stat_SPA} spd {pk.Stat_SPD}")}  moves {Moves(pk)}  [{Legality(pk)}]";
    }

    static void Show(string path)
    {
        var sav = Load(path);
        Console.WriteLine($"== {path}");
        Console.WriteLine($"   {sav.GetType().Name} trainer {sav.OT}/{sav.TID16:D5}  checksums {(sav.ChecksumsValid ? "ok" : "BAD")}  money {sav.Money}");
        var party = Party(sav);
        Console.WriteLine($"   party ({party.Count})");
        for (int i = 0; i < party.Count; i++) Console.WriteLine($"     {i + 1}. {Describe(party[i])}");
        var boxed = Boxed(sav);
        Console.WriteLine($"   boxes ({boxed.Count})");
        foreach (var (b, s, pk) in boxed) Console.WriteLine($"     box {b} slot {s}: {Describe(pk)}");
    }

    // What makes one mon the same mon across a trade: trainer, DVs, EXP and
    // stat exp do not change when it changes hands or evolves.
    static string Key(GBPKM pk) => $"{pk.OriginalTrainerName}|{pk.TID16}|{pk.DV16}|{pk.EXP}|{StatExp(pk)}";

    static readonly Dictionary<string, string> TradeEvolutions = new()
    {
        ["Kadabra"] = "Alakazam", ["Machoke"] = "Machamp", ["Graveler"] = "Golem", ["Haunter"] = "Gengar",
    };

    static int Trade(string mineBefore, string mineAfter, string theirsBefore)
    {
        var before = Load(mineBefore);
        var after = Load(mineAfter);
        var theirs = Load(theirsBefore);
        Console.WriteLine($"== trade check for {before.OT}/{before.TID16:D5}, partner {theirs.OT}/{theirs.TID16:D5}");

        Check(after.OT == before.OT && after.TID16 == before.TID16, "trainer name and ID unchanged");
        var pb = Party(before);
        var pa = Party(after);
        var pt = Party(theirs).Concat(Boxed(theirs).Select(x => x.pk)).ToList();

        var beforeKeys = pb.Select(Key).ToList();
        var afterKeys = pa.Select(Key).ToList();
        var left = pb.Where(pk => !afterKeys.Contains(Key(pk))).ToList();
        var arrived = pa.Where(pk => !beforeKeys.Contains(Key(pk))).ToList();
        foreach (var pk in left) Console.WriteLine($"   gave:     {Describe(pk)}");
        foreach (var pk in arrived) Console.WriteLine($"   received: {Describe(pk)}");
        Check(left.Count == arrived.Count && left.Count > 0, $"{left.Count} mon(s) left and {arrived.Count} arrived");
        Check(pa.Count == pb.Count, $"party size unchanged ({pb.Count} -> {pa.Count})");

        // the cartridge closes the gap and files the arrival at the end
        var stayed = pb.Where(pk => afterKeys.Contains(Key(pk))).ToList();
        for (int i = 0; i < stayed.Count && i < pa.Count; i++)
            Check(Key(pa[i]) == Key(stayed[i]) && pa[i].Data.SequenceEqual(stayed[i].Data),
                  $"slot {i + 1} is {Name(stayed[i].Species)}, unchanged byte for byte");
        for (int i = 0; i < arrived.Count; i++)
            Check(Key(pa[pa.Count - arrived.Count + i]) == Key(arrived[i]), $"arrival {i + 1} filed at the end of the party");

        foreach (var got in arrived)
        {
            var src = pt.FirstOrDefault(pk => Key(pk) == Key(got));
            Check(src != null, $"{Name(got.Species)} came from {theirs.OT}'s save");
            if (src == null) continue;
            // Gen 1 has no Everstone: a trade-evolution species always evolves on arrival
            string from = Name(src.Species), to = Name(got.Species);
            if (TradeEvolutions.TryGetValue(from, out var evo))
                Check(to == evo, to == evo ? $"{from} became {to} (a trade evolution)" : $"{from} should have evolved into {evo}, arrived as {to}");
            else
                Check(to == from, $"species kept ({to})");
            Check(got.OriginalTrainerName == src.OriginalTrainerName && got.TID16 == src.TID16,
                  $"OT {got.OriginalTrainerName}/{got.TID16:D5} kept");
            Check(got.DV16 == src.DV16, $"DVs {Dvs(got)} kept");
            Check(StatExp(got) == StatExp(src) && got.EXP == src.EXP, "stat exp and EXP kept");
            Check(got.CurrentLevel == src.CurrentLevel, $"level {got.CurrentLevel} kept");
            Check(Moves(got) == Moves(src), $"moves kept ({Moves(got)})");
            Check(got.IsNicknamed == src.IsNicknamed && (!src.IsNicknamed || got.Nickname == src.Nickname),
                  src.IsNicknamed ? $"nickname \"{got.Nickname}\" kept" : "no nickname, as sent");
            var expected = ConvertFor(src, got);
            if (got is PK1 g1)
                Check(g1.CatchRate == ((PK1)expected).CatchRate,
                      src is PK1 ? $"catch-rate byte {g1.CatchRate} kept"
                                 : $"held item 0x{src.HeldItem:X2} became catch-rate byte {g1.CatchRate} (PKHeX expects {((PK1)expected).CatchRate})");
            else
                Check(got.HeldItem == expected.HeldItem,
                      src is PK2 ? $"held item 0x{got.HeldItem:X2} kept"
                                 : $"catch-rate byte {((PK1)src).CatchRate} became held item 0x{got.HeldItem:X2} (PKHeX expects 0x{expected.HeldItem:X2})");
            Check(got.Stat_HPCurrent <= got.Stat_HPMax && got.Stat_HPCurrent > 0, $"HP {got.Stat_HPCurrent}/{got.Stat_HPMax}");
            var la = new LegalityAnalysis(got);
            Check(la.Valid, "PKHeX legality: " + (la.Valid ? "legal" : la.Report().Replace(Environment.NewLine, " | ")));
        }

        var bb = Boxed(before).Select(x => Key(x.pk)).ToList();
        var ba = Boxed(after).Select(x => Key(x.pk)).ToList();
        Check(bb.SequenceEqual(ba), $"PC boxes unchanged ({bb.Count} mons)");
        Console.WriteLine(failures == 0 ? "PASS" : $"FAIL ({failures})");
        return failures == 0 ? 0 : 1;
    }

    // Gen 2 trade evolutions (data/pokemon/evos_attacks.asm): into, and the
    // held item the row demands (0 = any trade); the item is consumed
    static readonly Dictionary<Species, (Species into, int item)> TradeEvolutions2 = new()
    {
        [Species.Kadabra] = (Species.Alakazam, 0), [Species.Machoke] = (Species.Machamp, 0),
        [Species.Graveler] = (Species.Golem, 0), [Species.Haunter] = (Species.Gengar, 0),
        [Species.Onix] = (Species.Steelix, 0x8F), [Species.Scyther] = (Species.Scizor, 0x8F),
        [Species.Poliwhirl] = (Species.Politoed, 0x52), [Species.Slowpoke] = (Species.Slowking, 0x52),
        [Species.Seadra] = (Species.Kingdra, 0x97), [Species.Porygon] = (Species.Porygon2, 0xAC),
    };
    const int Everstone = 0x70;

    // one mon in the replay: the record it started as, what it should be now
    sealed record Expect(GBPKM Src, ushort Species, int Item, bool Moved, bool Evolved);

    static Expect Arrive(Expect e)
    {
        ushort species = e.Species;
        int item = e.Item;
        bool evolved = e.Evolved;
        if (!e.Src.IsEgg && item != Everstone
            && TradeEvolutions2.TryGetValue((Species)species, out var evo) && (evo.item == 0 || evo.item == item))
        {
            species = (ushort)evo.into;
            evolved = true;
            if (evo.item != 0) item = 0;
        }
        return new Expect(e.Src, species, item, true, evolved);
    }

    static int Trades(string mineBefore, string mineAfter, string theirsBefore, string rounds)
    {
        var before = Load(mineBefore);
        var after = Load(mineAfter);
        var theirs = Load(theirsBefore);
        Console.WriteLine($"== trades check for {before.OT}/{before.TID16:D5}, partner {theirs.OT}/{theirs.TID16:D5}, rounds {rounds}");
        Check(after.OT == before.OT && after.TID16 == before.TID16, "trainer name and ID unchanged");

        var mine = Party(before).Select(pk => new Expect(pk, pk.Species, pk.HeldItem, false, false)).ToList();
        var other = Party(theirs).Select(pk => new Expect(pk, pk.Species, pk.HeldItem, false, false)).ToList();
        int r = 0;
        foreach (var spec in rounds.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            r++;
            var parts = spec.Split('/');
            int m = int.Parse(parts[0]) - 1, t = int.Parse(parts[1]) - 1;
            if (m < 0 || m >= mine.Count || t < 0 || t >= other.Count)
            {
                Fail($"round {r}: slot {spec} is outside the parties ({mine.Count}/{other.Count})");
                return 1;
            }
            var gave = mine[m];
            var got = other[t];
            mine.RemoveAt(m);
            other.RemoveAt(t);
            var arrived = Arrive(got);
            mine.Add(arrived);
            other.Add(Arrive(gave));
            var evolvedNote = arrived.Species != got.Species ? $", which evolves into {Name(arrived.Species)}" : "";
            Console.WriteLine($"   round {r}: gave {Name(gave.Species)} (slot {m + 1}), received {Name(got.Species)} (their slot {t + 1}){evolvedNote}");
        }

        var pa = Party(after);
        Check(pa.Count == mine.Count, $"party size {pa.Count} (the replay says {mine.Count})");
        for (int i = 0; i < Math.Min(pa.Count, mine.Count); i++)
        {
            var got = pa[i];
            var e = mine[i];
            var src = e.Src;
            var label = $"slot {i + 1}";
            Check(Key(got) == Key(src),
                  $"{label}: {Name(got.Species)} is {src.OriginalTrainerName}'s {Name(src.Species)} (trainer, DVs, EXP and stat exp match)");
            if (!e.Moved)
            {
                Check(got.Data.SequenceEqual(src.Data), $"{label}: never traded, unchanged byte for byte");
                continue;
            }
            Console.WriteLine($"   {label} arrived: {Describe(got)}");
            Check(got.Species == e.Species,
                  e.Evolved ? $"{label}: {Name(src.Species)} trade-evolved into {Name(got.Species)} (expected {Name(e.Species)})"
                            : $"{label}: species kept ({Name(got.Species)}, expected {Name(e.Species)})");
            Check(got.HeldItem == e.Item,
                  e.Item != src.HeldItem ? $"{label}: held item 0x{src.HeldItem:X2} consumed by the evolution (now 0x{got.HeldItem:X2})"
                                         : $"{label}: held item 0x{got.HeldItem:X2} kept (expected 0x{e.Item:X2})");
            Check(got.OriginalTrainerName == src.OriginalTrainerName && got.TID16 == src.TID16,
                  $"{label}: OT {got.OriginalTrainerName}/{got.TID16:D5} kept");
            Check(got.CurrentLevel == src.CurrentLevel, $"{label}: level {got.CurrentLevel} kept");
            ushort[] gm = [got.Move1, got.Move2, got.Move3, got.Move4];
            ushort[] sm = [src.Move1, src.Move2, src.Move3, src.Move4];
            int[] gp = [got.Move1_PP, got.Move2_PP, got.Move3_PP, got.Move4_PP];
            int[] sp = [src.Move1_PP, src.Move2_PP, src.Move3_PP, src.Move4_PP];
            bool movesOk = true;
            for (int k = 0; k < 4; k++)
                if (sm[k] != 0 && (gm[k] != sm[k] || gp[k] != sp[k])) movesOk = false;
                else if (sm[k] == 0 && gm[k] != 0 && !e.Evolved) movesOk = false;
            Check(movesOk, e.Evolved ? $"{label}: moves kept, new ones only in free slots ({Moves(got)})"
                                     : $"{label}: moves kept ({Moves(got)})");
            Check(got.IsNicknamed == src.IsNicknamed && (!src.IsNicknamed || got.Nickname == src.Nickname),
                  src.IsNicknamed ? $"{label}: nickname \"{got.Nickname}\" kept" : $"{label}: no nickname, named {got.Nickname}");
            if (got is PK2 g2 && src is PK2 s2)
                Check(g2.CurrentFriendship == s2.CurrentFriendship && g2.PokerusState == s2.PokerusState
                      && g2.CaughtData == s2.CaughtData,
                      $"{label}: happiness {g2.CurrentFriendship}, pokerus and caught data kept");
            Check(got.Stat_HPCurrent <= got.Stat_HPMax && (got.Stat_HPCurrent > 0 || src.Stat_HPCurrent == 0),
                  $"{label}: HP {got.Stat_HPCurrent}/{got.Stat_HPMax}");
            var la = new LegalityAnalysis(got);
            Check(la.Valid, $"{label}: PKHeX legality: " + (la.Valid ? "legal" : la.Report().Replace(Environment.NewLine, " | ")));
        }

        var bb = Boxed(before).Select(x => Key(x.pk)).ToList();
        var ba = Boxed(after).Select(x => Key(x.pk)).ToList();
        Check(bb.SequenceEqual(ba), $"PC boxes unchanged ({bb.Count} mons)");
        Console.WriteLine(failures == 0 ? "PASS" : $"FAIL ({failures})");
        return failures == 0 ? 0 : 1;
    }

    static void Check(bool ok, string what)
    {
        Console.WriteLine($"   {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) failures++;
    }

    static void Fail(string what)
    {
        Console.WriteLine($"   FAIL {what}");
        failures++;
    }
}
