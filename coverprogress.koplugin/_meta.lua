local _ = require("gettext")
return {
    name = "coverprogress",
    fullname = _("Cover screensaver with progress"),
    description = _([[Writes the current book's cover, with a reading-progress overlay, to a fixed image path so an external screensaver app can display it.

Four layouts are available: a bar in the margin below the cover, a bar below a slightly shrunk cover, a bar overlaid on the cover, or a Kobo-style information box. Updates as you read.

Derived from KOReader's built-in coverimage plugin.]]),
}
