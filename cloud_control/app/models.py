from tortoise import fields, models
from tortoise.contrib.pydantic import pydantic_model_creator

class User(models.Model):
    id = fields.IntField(pk=True)
    username = fields.CharField(max_length=50, unique=True)
    password_hash = fields.CharField(max_length=128)
    role = fields.CharField(max_length=20, default="user") # admin, agent, user
    parent = fields.ForeignKeyField('models.User', related_name='children', null=True)
    created_at = fields.DatetimeField(auto_now_add=True)

    class PydanticMeta:
        exclude = ["password_hash"]

class Device(models.Model):
    id = fields.IntField(pk=True)
    udid = fields.CharField(max_length=60, unique=True)
    name = fields.CharField(max_length=100, null=True)
    status = fields.CharField(max_length=20, default="offline") # online, offline, busy
    owner = fields.ForeignKeyField('models.User', related_name='devices', null=True)
    last_heartbeat = fields.DatetimeField(null=True)
    local_ip = fields.CharField(max_length=50, null=True)
    created_at = fields.DatetimeField(auto_now_add=True)

class Script(models.Model):
    id = fields.IntField(pk=True)
    name = fields.CharField(max_length=100)
    content = fields.TextField()
    version = fields.CharField(max_length=20, default="1.0")
    created_by = fields.ForeignKeyField('models.User', related_name='scripts')
    created_at = fields.DatetimeField(auto_now_add=True)

class Task(models.Model):
    id = fields.IntField(pk=True)
    device = fields.ForeignKeyField('models.Device', related_name='tasks')
    script = fields.ForeignKeyField('models.Script', related_name='tasks', null=True)
    type = fields.CharField(max_length=50, default="SCRIPT") # SCRIPT, VPN, CONTROL
    payload = fields.JSONField(null=True) # For ad-hoc scripts or params
    status = fields.CharField(max_length=20, default="pending") # pending, running, success, failed
    result = fields.TextField(null=True)
    created_at = fields.DatetimeField(auto_now_add=True)
    finished_at = fields.DatetimeField(null=True)

class Log(models.Model):
    id = fields.IntField(pk=True)
    device = fields.ForeignKeyField('models.Device', related_name='logs')
    action = fields.CharField(max_length=50)
    message = fields.TextField()
    timestamp = fields.DatetimeField(auto_now_add=True)
