/**
 * @presideService true
 * @singleton      true
 */
component {

// CONSTRUCTOR
	/**
	 * @validAlertLevels.inject  coldbox:setting:enum.systemAlertLevel
	 *
	 */
	public any function init( required array validAlertLevels ) {
		_setValidAlertLevels( arguments.validAlertLevels );

		return this;
	}

// PUBLIC API METHODS
	public void function setupSystemAlerts() {
		_discoverSystemAlertTypes();
	}

	public any function runCheck( required string type, string reference="", boolean async=true ) {
		var checkHandler = "admin.systemAlerts.#arguments.type#.runCheck";
		var config       = getAlertConfig( arguments.type );

		if ( !$getColdbox().handlerExists( checkHandler ) ) {
			return;
		}

		if ( arguments.async ) {
			$createTask(
				  event             = "admin.systemAlerts.runCheckInBackgroundThread"
				, args              = { type=arguments.type, reference=arguments.reference }
				, runNow            = true
				, discardOnComplete = false
			);
			return;
		}

		var references = [ arguments.reference ];
		if ( config.isMultiCheck ) {
			references = $runEvent(
				  event         = "admin.systemAlerts.#arguments.type#.references"
				, private       = true
				, prepostExempt = true
			);
		}

		for( var ref in references ) {
			var check = new SystemAlertCheck( type=arguments.type, reference=ref );
			$runEvent(
				  event          = checkHandler
				, private        = true
				, prepostExempt  = true
				, eventArguments = { check=check }
			);

			if ( check.fails() ) {
				_raiseAlert(
					  type      = arguments.type
					, reference = ref
					, level     = check.getLevel()
					, data      = check.getData()
				);
			} else {
				_clearAlert(
					  type      = arguments.type
					, reference = ref
				);
			}

			if ( !config.isMultiCheck ) {
				return check;
			}
		}
	}

	public string function rerunCheck( required string id ) {
		var alert = _getRawAlertById( arguments.id );
		if ( StructIsEmpty( alert ) ) {
			return "notfound";
		}
		var check = runCheck( type=alert.type, reference=alert.reference, async=false );

		return check.fails() ? "fails" : "cleared";
	}

	public struct function getAlert( string id="", string type="", string reference="" ) {
		var alert = {};
		if ( Len( arguments.id ) ) {
			alert = _getRawAlertById( arguments.id );
		} else {
			alert = _getRawAlertByType( type=arguments.type, reference=arguments.reference );
		}

		return _decorateAlert( alert );
	}

	public void function runStartupChecks() {
		for( var type in _getStartupChecks() ) {
			runCheck( type=type );
		}
	}

	public void function runWatchedSettingsChecks( required string category ) {
		var categories = _getWatchedSettingsCategories();
		var types      = categories[ arguments.category ] ?: [];

		for( var type in types ) {
			runCheck( type=type );
		}
	}


// PUBLIC HELPERS
	public array function getAlertTypes() {
		return StructKeyArray( _getAlertConfigs() );
	}

	public array function getAlertLevels() {
		return _getValidAlertLevels();
	}

	public struct function getAlertConfig( required string alertType ) {
		var alertConfigs = _getAlertConfigs();

		return alertConfigs[ arguments.alertType ] ?: {};
	}

	public struct function getAlertCounts() {
		var counts = {
			  critical = 0
			, warning  = 0
			, advisory = 0
			, total    = 0
		};
		var countQuery = $getPresideObject( "system_alert" ).selectData(
			  selectFields = [ "level", "count( level ) as alerts" ]
			, groupBy      = "level"
		);

		for( var level in countQuery ) {
			counts[ level.level ] = level.alerts;
			counts.total += level.alerts;
		}

		return counts;
	}


// PRIVATE HELPERS
	private void function _discoverSystemAlertTypes() {
		var configs                   = {};
		var watchedSettingsCategories = {};
		var startupChecks             = [];
		var coldbox                   = $getColdbox();
		var alertHandlers             = coldbox.listHandlers( thatStartWith="admin.systemAlerts." )

		for( var handler in alertHandlers ) {
			var type = ListLast( handler, "." );

			if ( !_getAlertSetting( type, "isEnabled", true ) ) {
				_clearAllOfType( type );
				continue;
			}

			// Base config
			var config = {
				  type         = type
				, defaultLevel = _getAlertSetting( type, "defaultLevel", "warning" )
				, context      = _getAlertSetting( type, "context", "" )
				, watchObjects = _getAlertSetting( type, "watchObjects", {} )
				, schedule     = _getAlertSetting( type, "schedule", "" )
				, isMultiCheck = coldbox.handlerExists( "admin.systemAlerts.#type#.references" )
			};

			if ( Len( config.schedule ) && !_crontabExpressionIsValid( config.schedule ) ) {
				config.schedule = "";
			}

			configs[ type ] = configs[ type ] ?: {};
			StructAppend( configs[ type ], config );

			// Startup checks
			if ( $helpers.isTrue( _getAlertSetting( type, "runAtStartup", false ) ) ) {
				ArrayAppend( startupChecks, type );
			}

			// Watched settings
			for( var category in _getAlertSetting( type, "watchSettingsCategories", [] ) ) {
				watchedSettingsCategories[ category ] = watchedSettingsCategories[ category ] ?: [];
				ArrayAppend( watchedSettingsCategories[ category ], type );
			}
		}

		_setAlertConfigs( configs );
		_setStartupChecks( startupChecks );
		_setWatchedSettingsCategories( watchedSettingsCategories );
		_setupSchedules( configs );
	}

	private any function _getAlertSetting( required string type, required string setting, required any defaultValue ) {
		var handler = "admin.systemAlerts.#arguments.type#.#arguments.setting#";

		if ( $getColdbox().handlerExists( handler ) ) {
			return $runEvent(
				  event         = handler
				, private       = true
				, prepostExempt = true
			);
		}

		return arguments.defaultValue;
	}

	private void function _raiseAlert(
		  required string type
		,          string reference = ""
		,          string level     = ""
		,          struct data      = {}
	) {
		if ( !_isValidAlertType( arguments.type) ) {
			try {
				throw(
				  	  type    = "SystemAlertsService.alert.type.not.found"
					, message = "The system alert type [#arguments.type#] has not been registered."
				);
			}
			catch( any e ) {
				$raiseError( e );
				return;
			}
		}

		var config   = getAlertConfig( arguments.type );
		var existing = _getRawAlertByType( type=arguments.type, reference=arguments.reference );
		var alert    = {
			  type      = arguments.type
			, context   = config.context
			, reference = arguments.reference
			, level     = _isValidAlertLevel( arguments.level ) ? arguments.level : config.defaultLevel
			, data      = serializeJSON( arguments.data )
		};

		if ( StructIsEmpty( existing ) ) {
			$getPresideObject( "system_alert" ).insertData( data=alert );
		} else {
			$getPresideObject( "system_alert" ).updateData( id=existing.id, data=alert );
		}
	}

	private struct function _getRawAlertById( required string id ) {
		var alert = $getPresideObject( "system_alert" ).selectData( id=arguments.id );

		for( var record in alert ) {
			return record;
		}
		return {};
	}

	private struct function _getRawAlertByType( required string type, string reference="" ) {
		var filter = { type=arguments.type, reference=arguments.reference };
		var alert  = $getPresideObject( "system_alert" ).selectData( filter=filter );

		for( var record in alert ) {
			return record;
		}
		return {};
	}

	private struct function _decorateAlert( required struct alert ) {
		if ( StructIsEmpty( arguments.alert ) ) {
			return {};
		}

		var type          = arguments.alert.type ?: "";
		var renderHandler = "admin.systemAlerts.#type#.render";

		if ( IsJSON( arguments.alert.data ?: "" ) ) {
			arguments.alert.data = DeserializeJSON( arguments.alert.data );
		}
		if ( !IsStruct( arguments.alert.data ?: "" ) ) {
			arguments.alert.data = {};
		}

		arguments.alert.title    = $translateResource( "systemAlerts.#type#:title" );
		arguments.alert.rendered = $getColdbox().viewletExists( renderHandler ) ? $renderViewlet( event=renderHandler, args=arguments.alert ) : "";

		if ( !Len( Trim( arguments.alert.rendered ?: "" ) ) ) {
			arguments.alert.rendered = $renderViewlet( event="admin.datamanager.system_alert._noRenderer" );
		}

		return arguments.alert;
	}

	private string function _renderDetail( required struct alert ) {
		var handler = "admin.systemAlerts.#type#.render";
	}

	private void function _clearAlert( required string type, string reference="" ) {
		var filter = { type=arguments.type, reference=arguments.reference };
		$getPresideObject( "system_alert" ).deleteData( filter=filter );
	}

	private void function _clearAllOfType( required string type ) {
		var filter = { type=arguments.type };
		$getPresideObject( "system_alert" ).deleteData( filter=filter );
	}

	private boolean function _isValidAlertType( required string type ) {
		return ArrayFindNoCase( getAlertTypes(), arguments.type ) ? true : false;
	}

	private boolean function _isValidAlertLevel( required string level ) {
		return ArrayFindNoCase( _getValidAlertLevels(), arguments.level ) ? true : false;
	}

// SCHEDULING
	public void function runScheduledChecks() {
		var dao       = $getPresideObject( "system_alert_schedule" );
		var nextCheck = NullValue();

		do {
			nextCheck = _getNextScheduledCheckToRun();

			if ( !IsNull( nextCheck ) ) {
				runCheck( nextCheck.type );
				dao.updateData(
					  id   = nextCheck.id
					, data = {
						  last_run = now()
						, next_run = _getNextRunDate( schedule=nextCheck.schedule, lastRun=now() )
					}
				);
			}
		} while( !IsNull( nextCheck ) );
	}

	private any function _getNextScheduledCheckToRun() {
		var dao       = $getPresideObject( "system_alert_schedule" );
		var nextCheck = dao.selectData(
			  selectFields = [ "id", "type", "schedule" ]
			, filter       = "next_run < :next_run"
			, filterparams = { next_run=Now() }
			, maxRows      = 1
			, orderBy      = "next_run"
			, useCache     = false
		);

		if ( nextCheck.recordCount ) {
			return nextCheck;
		}

		return;
	}

	private void function _setupSchedules( required struct configs ) {
		var dao          = $getPresideObject( "system_alert_schedule" );
		var existingSchedules = dao.selectData();
		var existing = {};
		var configs      = {};

		for( var schedule in existingSchedules ) {
			if ( !Len( config[ schedule.type ].schedule ?: "" ) ) {
				dao.deleteData( id=schedule.id );
			} else {
				existing[ schedule.type ] = schedule;
			}
		}

		for( var type in arguments.configs ) {
			config = arguments.configs[ type ];
			if ( !Len( config.schedule ) ) {
				continue;
			}
			if ( !StructKeyExists( existing, "type" ) ) {
				dao.insertData( data={
					  type     = type
					, schedule = config.schedule
					, next_run = _getNextRunDate( config.schedule )
				} );
				continue;
			}
			if ( config.schedule != ( existing[ type ].schedule ) ) {
				dao.updateData(
					  id   = existing[ type ].id
					, data = {
						  schedule = config.schedule
						, next_run = _getNextRunDate( schedule=config.schedule, lastRun=Len( existing[ type ].last_run ) ? existing[ type ].last_run : now() )
					}
				);
			}
		}
	}

	private string function _getNextRunDate( required string schedule, date lastRun=now() ) {
		var cronTabExpression = _getCrontabExpressionObject( arguments.schedule );
		var lastRunJodaTime   = _createJodaTimeObject( arguments.lastRun );

		return cronTabExpression.nextTimeAfter( lastRunJodaTime  ).toDate();
	}

	private array function _getLib() {
		return [
			  "/preside/system/services/taskmanager/lib/cron-parser-2.6-SNAPSHOT.jar"
			, "/preside/system/services/taskmanager/lib/commons-lang3-3.3.2.jar"
			, "/preside/system/services/taskmanager/lib/joda-time-2.9.4.jar"
			, "/preside/system/services/taskmanager/lib/cron-1.0.jar"
		];
	}

	private boolean function _crontabExpressionIsValid( required string crontabExpression ) {
		try {
			_getCrontabExpressionObject( arguments.cronTabExpression );
		} catch ( any e ) {
			$raiseError( e );
			return false;
		}

		return true;
	}

	private any function _getCrontabExpressionObject( required string expression ) {
		return CreateObject( "java", "fc.cron.CronExpression", _getLib() ).init( arguments.expression );
	}

	private any function _createJodaTimeObject( required date cfmlDateTime ) {
		return CreateObject( "java", "org.joda.time.DateTime", _getLib() ).init( cfmlDateTime );
	}

// GETTERS AND SETTERS
	private struct function _getAlertConfigs() {
		return variables._alertConfigs ?: {};
	}
	private void function _setAlertConfigs( required struct alertConfigs ) {
		variables._alertConfigs = arguments.alertConfigs;
	}

	private array function _getStartupChecks() {
		return variables._startupChecks ?: [];
	}
	private void function _setStartupChecks( required array startupChecks ) {
		variables._startupChecks = arguments.startupChecks;
	}

	private struct function _getWatchedSettingsCategories() {
		return variables._watchedSettingsCategories ?: {};
	}
	private void function _setWatchedSettingsCategories( required struct watchedSettingsCategories ) {
		variables._watchedSettingsCategories = arguments.watchedSettingsCategories;
	}

	private array function _getValidAlertLevels() {
		return variables._validAlertLevels;
	}
	private void function _setValidAlertLevels( required array validAlertLevels ) {
		variables._validAlertLevels = arguments.validAlertLevels;
	}

}