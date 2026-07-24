local _ = require("gettext")
return {
    name = "coverprogress",
    fullname = _("Cover screensaver with progress"),
    description = _([[Writes the current book's cover, with a reading-progress overlay, to a fixed image path so an external screensaver app can display it.

Three layouts are available: a bar below the cover, a bar over the cover, or a Kobo-style information box. Updates as you read.

Derived from KOReader's built-in coverimage plugin.]]),
}
