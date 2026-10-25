import ballerina/ai;
import ballerina/http;
import ballerina/io;
import ballerina/workflow;
import ballerina/workflow.management;

type Claim record {|
    string claimId;
    string employee;
    string category;
    decimal amount;
    string description;
|};

# The policy agent's typed verdict, returned by `waitForResult`.
#
# + withinPolicy - Whether the claim follows the expense policy
# + riskLevel - LOW, MEDIUM or HIGH
# + reasoning - Why, in one or two sentences, shown to the reviewer
type PolicyAssessment record {|
    boolean withinPolicy;
    string riskLevel;
    string reasoning;
|};

# A finance reviewer's decision on a flagged claim.
#
# + approved - Whether the claim is paid
# + comment - The reviewer's comment
type ReviewDecision record {|
    boolean approved;
    string comment;
|};

type ClaimResult record {|
    string claimId;
    string status;
    string note;
|};

const decimal AUTO_APPROVE_LIMIT = 200.00;

final ai:Wso2ModelProvider policyModel = check ai:getDefaultModelProvider();

# Returns the expense policy text for a category.
#
# + category - Expense category, such as travel, meals or equipment
# + return - The policy rules for the category
@workflow:Activity
function lookupPolicy(string category) returns string|error {
    match category {
        "meals" => {
            return "Meals: up to 50 per person per day. Alcohol is not reimbursed.";
        }
        "travel" => {
            return "Travel: economy class only. Taxis allowed when no public transport is available.";
        }
        _ => {
            return "Other: any single item above 500 needs a business justification.";
        }
    }
}

# Returns the employee's recent claim count, to spot unusual patterns.
#
# + employee - The employee id
# + return - A short summary of recent claims
@workflow:Activity
function recentClaims(string employee) returns string|error {
    return string `${employee} filed 2 claims in the last 30 days, both approved.`;
}

@workflow:Activity
function validateClaim(Claim claim) returns string|error {
    if claim.amount <= 0d {
        return error("Claim amount must be positive");
    }
    return "valid";
}

@workflow:Activity
function payClaim(string claimId, decimal amount) returns string|error {
    io:println(string `[activity] paying ${claimId}: ${amount}`);
    return string `PAY-${claimId}`;
}

// The agent's reasoning and every tool call are durable: a crash mid-assessment resumes from history.
final workflow:DurableAgent policyAgent = check new ({
    systemPrompt: {
        role: "You are an expense policy checker.",
        instructions: string `Check the claim in the input against the expense policy.
                Use lookupPolicy for the claim's category and recentClaims for the employee.
                Decide whether the claim is within policy and rate its risk as LOW, MEDIUM or HIGH.`
    },
    model: policyModel,
    inputType: Claim,
    resultType: PolicyAssessment,
    activities: [lookupPolicy, recentClaims]
});

@workflow:Workflow
function processClaim(workflow:Context ctx, Claim claim) returns ClaimResult|error {
    string _ = check ctx->callActivity(validateClaim, {"claim": claim});

    string assessmentId = check policyAgent.run("Assess this expense claim.", claim);
    PolicyAssessment assessment = check policyAgent.waitForResult(assessmentId);

    if assessment.withinPolicy && assessment.riskLevel == "LOW" && claim.amount <= AUTO_APPROVE_LIMIT {
        string paymentId = check ctx->callActivity(payClaim, {"claimId": claim.claimId, "amount": claim.amount});
        return {claimId: claim.claimId, status: "PAID", note: string `Auto-approved: ${paymentId}`};
    } else {
        ReviewDecision decision = check ctx->awaitHumanTask("reviewClaim",
                {claimId: claim.claimId, amount: claim.amount.toString(), category: claim.category,
                    agentRisk: assessment.riskLevel, agentReasoning: assessment.reasoning},
                userRoles = "FINANCE", title = string `Review claim ${claim.claimId}`);
        if decision.approved {
            string paymentId = check ctx->callActivity(payClaim, {"claimId": claim.claimId, "amount": claim.amount});
            return {claimId: claim.claimId, status: "PAID", note: string `Approved by finance: ${paymentId}`};
        } else {
            return {claimId: claim.claimId, status: "REJECTED", note: decision.comment};
        }
    }
}

service /claims on new http:Listener(8090) {

    resource function post .(Claim claim) returns record {|string workflowId;|}|error {
        string workflowId = check workflow:run(processClaim, claim);
        return {workflowId};
    }

    resource function get [string workflowId]() returns json|error {
        ClaimResult|error result = workflow:getResult(workflowId);
        if result is workflow:WorkflowInProgressError {
            return {workflowId, status: "IN_PROGRESS"};
        }
        return check result;
    }

    resource function get [string workflowId]/tasks() returns management:HumanTaskGroup[]|error {
        return management:listPendingHumanTasks(workflowId);
    }

    resource function post tasks/[string taskId]/complete(ReviewDecision decision) returns string|error {
        check workflow:completeHumanTask(taskId, decision, ["FINANCE"]);
        return string `Task ${taskId} completed`;
    }
}
