"use strict";

// Runtime configuration of the Diapason web app. Empty values mean "no preset".
// The Docker image overwrites this file from its environment at container start
// (docker/diapason-config.js.template); see docs/WEB_DOCKER.md.
window.diapasonConfig = {
  SERVER_NAME: "",
  SERVER_TYPE: "",
  SERVER_URL: "",
  SERVER_LOCK: "false",
};
