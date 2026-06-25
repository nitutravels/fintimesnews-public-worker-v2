# Preproduction status

The private repository connection test has passed.

The next workflow is a manual, non-publishing preflight. It validates the Azure Speech and YouTube OAuth secrets, renders a short generic test video, and saves only that generic video as a short-lived artifact.

It does not use or export the private anchor image, does not create a talking avatar, does not upload to YouTube, and has no automatic schedule.
