// savecheck: read Gen 1 cartridge saves with PKHeX.Core and check a trade.
//
//   savecheck show <file.sav>...                 trainer, party, boxes, legality
//   savecheck trade <mine_before.sav> <mine_after.sav> <theirs_before.sav>
//       what left my party, what arrived, and whether the arrival is the
//       other player's mon with its trainer, DVs, stat exp, EXP, moves and
//       nickname intact (species may differ only by a trade evolution)
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
        Console.Error.WriteLine("usage: savecheck show <file.sav>...");
        Console.Error.WriteLine("       savecheck trade <mine_before.sav> <mine_after.sav> <theirs_before.sav>");
        return 2;
    }

    static SAV1 Load(string path)
    {
        // PKHeX's own detection, the same as opening the file in PKHeX
        if (!SaveUtil.TryGetSaveFile(path, out var file) || file is not SAV1 sav)
            throw new InvalidDataException($"{path}: PKHeX does not recognize this as a Gen 1 save");
        if (!sav.ChecksumsValid) Fail($"{path}: checksums are not valid");
        return sav;
    }

    static List<PK1> Party(SAV1 sav)
    {
        var list = new List<PK1>();
        for (int i = 0; i < sav.PartyCount; i++) list.Add((PK1)sav.GetPartySlotAtIndex(i));
        return list;
    }

    static List<(int box, int slot, PK1 pk)> Boxed(SAV1 sav)
    {
        var list = new List<(int, int, PK1)>();
        for (int b = 0; b < sav.BoxCount; b++)
            for (int s = 0; s < sav.BoxSlotCount; s++)
            {
                var pk = (PK1)sav.GetBoxSlotAtIndex(b, s);
                if (pk.Species != 0) list.Add((b + 1, s + 1, pk));
            }
        return list;
    }

    static string Name(ushort species) => GameInfo.Strings.specieslist[species];
    static string MoveName(ushort move) => GameInfo.Strings.movelist[move];

    // Gen 1 DVs, unpacked from the cartridge's two bytes: attack, defense,
    // speed, special, and HP from their low bits.
    static string Dvs(PK1 pk)
    {
        int d = pk.DV16;
        int atk = (d >> 12) & 15, def = (d >> 8) & 15, spe = (d >> 4) & 15, spc = d & 15;
        int hp = ((atk & 1) << 3) | ((def & 1) << 2) | ((spe & 1) << 1) | (spc & 1);
        return $"{hp}/{atk}/{def}/{spe}/{spc}";
    }

    static string StatExp(PK1 pk) => $"{pk.EV_HP}/{pk.EV_ATK}/{pk.EV_DEF}/{pk.EV_SPE}/{pk.EV_SPC}";

    static string Moves(PK1 pk)
    {
        var parts = new List<string>();
        ushort[] moves = [pk.Move1, pk.Move2, pk.Move3, pk.Move4];
        int[] pp = [pk.Move1_PP, pk.Move2_PP, pk.Move3_PP, pk.Move4_PP];
        for (int i = 0; i < 4; i++) if (moves[i] != 0) parts.Add($"{MoveName(moves[i])} {pp[i]}");
        return string.Join(", ", parts);
    }

    static string Legality(PK1 pk)
    {
        var la = new LegalityAnalysis(pk);
        return la.Valid ? "legal" : "NOT LEGAL: " + la.Report().Replace(Environment.NewLine, " | ");
    }

    static string Describe(PK1 pk)
    {
        var nick = pk.IsNicknamed ? $" \"{pk.Nickname}\"" : "";
        return $"{Name(pk.Species)}{nick} L{pk.CurrentLevel}  OT {pk.OriginalTrainerName}/{pk.TID16:D5}"
             + $"  DVs {Dvs(pk)}  statexp {StatExp(pk)}  exp {pk.EXP}  catch {pk.CatchRate}"
             + $"\n        HP {pk.Stat_HPCurrent}/{pk.Stat_HPMax} atk {pk.Stat_ATK} def {pk.Stat_DEF}"
             + $" spe {pk.Stat_SPE} spc {pk.Stat_SPC}  moves {Moves(pk)}  [{Legality(pk)}]";
    }

    static void Show(string path)
    {
        var sav = Load(path);
        Console.WriteLine($"== {path}");
        Console.WriteLine($"   trainer {sav.OT}/{sav.TID16:D5}  checksums {(sav.ChecksumsValid ? "ok" : "BAD")}  money {sav.Money}");
        var party = Party(sav);
        Console.WriteLine($"   party ({party.Count})");
        for (int i = 0; i < party.Count; i++) Console.WriteLine($"     {i + 1}. {Describe(party[i])}");
        var boxed = Boxed(sav);
        Console.WriteLine($"   boxes ({boxed.Count})");
        foreach (var (b, s, pk) in boxed) Console.WriteLine($"     box {b} slot {s}: {Describe(pk)}");
    }

    // What makes one mon the same mon across a trade: trainer, DVs, EXP and
    // stat exp do not change when it changes hands or evolves.
    static string Key(PK1 pk) => $"{pk.OriginalTrainerName}|{pk.TID16}|{pk.DV16}|{pk.EXP}|{StatExp(pk)}";

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
            Check(got.CatchRate == src.CatchRate, $"catch-rate byte {got.CatchRate} kept");
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
