<!---@feature admin and emailCenter--->
<cfparam name="args.viewlink">
<cfparam name="args.viewlogtitle">
<cfoutput>
	<div class="action-buttons btn-group">
		<a href="#args.viewLink#" data-toggle="bootbox-modal" data-buttons="ok" data-title="#HtmlEditFormat( args.viewlogtitle )#" data-modal-class="full-screen-dialog">
			<i class="fa fa-eye"></i>
		</a>
	</div>
</cfoutput>