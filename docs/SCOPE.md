# Project scope

Music Manager moves *your own* music from the Music app on your Mac to a Garmin device you connect to that Mac. Data flows one way for music: Mac library → device. By design it does **not** read, list or copy the music library of other devices (for example an iPhone or iPad), and no such feature is planned. It does not remove copy protection (DRM) from any file. Please use it only with music you have the right to copy. Pull requests adding access to other devices' libraries will not be accepted.

**Technical note.** The only files the app reads back from a device are small text files: the device's playlist files (M3U8, to show and import their track lists), a check copy of a playlist it has just written, and `GarminDevice.xml`. They go to a temporary folder that is deleted right away. Audio files are never copied from the device to the Mac; a playlist track that is not already in your Mac library is shown as "device only" and is not transferred.
