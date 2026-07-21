// wandsmith: UAssetAPI round-trip CLI for the Solarpunk wand content pak.
//   wandsmith tojson   <usmap> <asset.uasset> <out.json>   [VER] [preload1;preload2;...]
//   wandsmith fromjson <usmap> <in.json> <out.uasset>      [VER] [preload1;preload2;...]
// Preloads: assets whose StructExports (BP classes, user structs) are registered into the
// usmap so externally-parented exports can be (de)serialized -- .usmap files only carry
// native schemas, blueprint schemas live in the assets themselves.
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

if (args.Length < 4)
{
    Console.Error.WriteLine("usage: wandsmith tojson|fromjson <usmap> <in> <out> [VER] [preloads]");
    return 2;
}

var cmd = args[0];
var usmap = new Usmap(args[1]);
var ver = args.Length > 4 ? Enum.Parse<EngineVersion>(args[4]) : EngineVersion.VER_UE5_7;

try
{
    if (args.Length > 5)
    {
        foreach (var pre in args[5].Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var preAsset = new UAsset(pre, ver, usmap);
            int added = 0;
            foreach (var exp in preAsset.Exports)
            {
                if (exp is StructExport sexp)
                {
                    var schema = Usmap.GetSchemaFromStructExport(sexp, usmap.AreFNamesCaseInsensitive);
                    if (schema != null)
                    {
                        usmap.Schemas[sexp.ObjectName.ToString()] = schema;
                        added++;
                    }
                }
            }
            Console.WriteLine($"preloaded {Path.GetFileName(pre)}: {added} schemas");
        }
    }

    if (cmd == "tojson")
    {
        var asset = new UAsset(args[2], ver, usmap);
        File.WriteAllText(args[3], asset.SerializeJson(Newtonsoft.Json.Formatting.Indented));
        Console.WriteLine($"OK tojson {args[2]} -> {args[3]}");
    }
    else if (cmd == "fromjson")
    {
        var asset = UAsset.DeserializeJson(File.ReadAllText(args[2]));
        asset.Mappings = usmap;
        asset.Write(args[3]);
        Console.WriteLine($"OK fromjson {args[2]} -> {args[3]}");
    }
    else
    {
        Console.Error.WriteLine($"unknown command {cmd}");
        return 2;
    }
}
catch (Exception e)
{
    Console.Error.WriteLine($"FAIL: {e.GetType().Name}: {e.Message}");
    Console.Error.WriteLine(e.StackTrace);
    return 1;
}
return 0;
