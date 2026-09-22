# LAMB Next -- Makefile : thin wrapper over lambctl.sh
# Real tabs are required for Make recipes.
.PHONY: help setup up down destroy admin-fix ollama-fix rebuild status

help:
	@./lambctl.sh usage

setup:
	@./lambctl.sh setup

build:
	@./lambctl.sh build

start:
	@./lambctl.sh up

stop:
	@./lambctl.sh down

clean:
	@./lambctl.sh destroy

admin-fix:
	@./lambctl.sh admin-fix

ollama-fix:
	@./lambctl.sh ollama-fix

rebuild:
	@./lambctl.sh rebuild

status:
	@./lambctl.sh status
