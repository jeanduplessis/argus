import Foundation

/// Generates short, human-readable two-word branch name suggestions
/// (e.g. "brave-otter") for new workspaces.
enum RandomBranchNameGenerator {
    /// Number of distinct adjective-noun combinations this generator can produce.
    static var combinationCount: Int { adjectives.count * nouns.count }

    static func generate(prefix: String = "") -> String {
        let adjective = adjectives.randomElement() ?? "brave"
        let noun = nouns.randomElement() ?? "otter"
        let words = "\(adjective)-\(noun)"

        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return words }
        return trimmedPrefix.hasSuffix("/") ? "\(trimmedPrefix)\(words)" : "\(trimmedPrefix)/\(words)"
    }

    private static let adjectives = [
        "agile", "amber", "ancient", "arctic", "auburn", "azure", "beaming", "blazing",
        "blissful", "bold", "boundless", "brave", "bright", "brisk", "bubbly", "calm",
        "canny", "chilly", "clever", "cosmic", "cozy", "crimson", "crisp", "curious",
        "dapper", "daring", "dazzling", "deft", "devoted", "diligent", "dreamy", "dusty",
        "eager", "earnest", "electric", "emerald", "epic", "fearless", "feisty", "fierce",
        "fleet", "fluent", "fond", "frosty", "gallant", "gentle", "giddy", "gleeful",
        "glossy", "golden", "grand", "grateful", "gritty", "happy", "hardy", "hasty",
        "hidden", "honest", "hopeful", "humble", "iconic", "indigo", "jaunty", "jolly",
        "jovial", "joyful", "keen", "kindly", "lively", "loyal", "lucid", "lucky",
        "lush", "majestic", "mellow", "merry", "mighty", "misty", "mystic", "nifty",
        "nimble", "noble", "nomad", "peaceful", "perky", "playful", "plucky", "polished",
        "proud", "quaint", "quick", "quiet", "radiant", "rapid", "resolute", "restless",
        "robust", "rugged", "rustic", "scarlet", "serene", "sharp", "shiny", "silent",
        "silver", "sleek", "sly", "smooth", "snappy", "solar", "sparky", "spirited",
        "spry", "steady", "stellar", "stormy", "sturdy", "sunny", "swift", "tidy",
        "tranquil", "trusty", "twilight", "unbowed", "upbeat", "valiant", "velvet", "vibrant",
        "vivid", "warm", "wary", "whimsical", "wild", "willing", "windy", "wise",
        "witty", "zealous", "zesty", "zippy",
    ]

    private static let nouns = [
        "acorn", "albatross", "anchor", "antelope", "atlas", "aurora", "badger", "banyan",
        "basil", "beacon", "beetle", "birch", "bison", "boulder", "bramble", "breeze",
        "brook", "canyon", "cardinal", "cedar", "cinder", "cliff", "cobra", "comet",
        "compass", "condor", "coral", "cove", "coyote", "crane", "crater", "cricket",
        "current", "cypress", "delta", "dolphin", "dune", "eagle", "ember", "estuary",
        "falcon", "fern", "firefly", "fjord", "forest", "fox", "gazelle", "geyser",
        "glacier", "glade", "gorge", "grove", "gull", "harbor", "hawk", "hazel",
        "heron", "hollow", "horizon", "hyacinth", "ibis", "island", "ivy", "jaguar",
        "jasmine", "juniper", "kestrel", "lagoon", "lantern", "lark", "lighthouse", "lily",
        "lynx", "magnolia", "mangrove", "maple", "marsh", "meadow", "meteor", "monsoon",
        "moose", "mountain", "narwhal", "nebula", "oasis", "oak", "orbit", "orca",
        "orchard", "osprey", "otter", "panther", "peak", "pebble", "pelican", "phoenix",
        "pine", "plateau", "plume", "prairie", "quartz", "rapids", "raven", "redwood",
        "reef", "ridge", "river", "rocket", "sage", "savanna", "sequoia", "shore",
        "sparrow", "sphinx", "spruce", "starling", "summit", "swan", "tarn", "thicket",
        "thistle", "thunder", "tiger", "timber", "toucan", "tundra", "valley", "vine",
        "vista", "voyager", "walnut", "warbler", "waterfall", "willow", "wolf", "wren",
    ]
}
