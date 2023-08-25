ACL=owner:git:rwx,pgrp:git:r-x,other::r--
ACTION_SCRIPT=/home/git/bin/gitea.init
ACTION_TIMEOUT=180
AUTO_START=always
SCRIPT_TIMEOUT=180
CHECK_INTERVAL=300
STOP_DEPENDENCIES=hard(intermediate:rac01d-git.vip)
START_DEPENDENCIES=hard(rac01d-git.vip) attraction(intermediate:rac01d-git.vip)
