from django.db import models
from django.contrib.auth.models import User
import time
import ipaddress
import uuid
from django.core.exceptions import ValidationError
import string


# Create your models here.

generate_uuid = lambda: str(uuid.uuid4())

class Customer(models.Model):
    user = models.OneToOneField(User)
    vat = models.CharField(max_length=255)

    ctime = models.DateTimeField(auto_now_add=True)
    mtime = models.DateTimeField(auto_now=True)

    uuid = models.CharField(max_length=36, default=generate_uuid, unique=True)

    def __unicode__(self):
        return self.user.username

class Server(models.Model):
    name = models.CharField(max_length=255,unique=True)
    address = models.GenericIPAddressField()

    hd = models.CharField(max_length=255,unique=True)

    memory = models.PositiveIntegerField("Memory MB")
    storage = models.PositiveIntegerField("Storage MB")

    ctime = models.DateTimeField(auto_now_add=True)
    mtime = models.DateTimeField(auto_now=True)

    uuid = models.CharField(max_length=36, default=generate_uuid, unique=True)

    @property
    def used_memory(self):
        return self.container_set.all().aggregate(models.Sum('memory'))['memory__sum']

    @property
    def used_storage(self):
        return self.container_set.all().aggregate(models.Sum('storage'))['storage__sum']

    @property
    def free_memory(self):
        return self.memory - self.used_memory

    @property
    def free_storage(self):
        return self.storage - self.used_storage

    def __unicode__(self):
        return "%s - %s" % (self.name, self.address)

class Distro(models.Model):
    name = models.CharField(max_length=255,unique=True)
    path = models.CharField(max_length=255,unique=True)

    ctime = models.DateTimeField(auto_now_add=True)
    mtime = models.DateTimeField(auto_now=True)

    uuid = models.CharField(max_length=36, default=generate_uuid, unique=True)

    def __unicode__(self):
        return self.name

class Container(models.Model):
    name = models.CharField(max_length=255)
    ssh_keys_raw = models.TextField("SSH keys")
    distro = models.ForeignKey(Distro)
    server = models.ForeignKey(Server)
    # in megabytes
    memory = models.PositiveIntegerField("Memory MB")
    storage = models.PositiveIntegerField("Storage MB")
    customer = models.ForeignKey(Customer)

    ctime = models.DateTimeField(auto_now_add=True)
    mtime = models.DateTimeField(auto_now=True)

    uuid = models.CharField(max_length=36, default=generate_uuid, unique=True)

    def __unicode__(self):
        return "%d (%s)" % (self.uid, self.name)

    # do not allow over-allocate memory or storage
    def clean(self):
        current_storage = self.server.container_set.all().aggregate(models.Sum('storage'))['storage__sum']
        current_memory = self.server.container_set.all().aggregate(models.Sum('memory'))['memory__sum']
        if self.pk:
            orig = Container.objects.get(pk=self.pk)
            current_storage -= orig.storage
            current_memory -= orig.memory
        if current_storage+self.storage > self.server.storage:
            raise ValidationError('the requested storage size is not available on the specified server')
        if current_memory+self.memory > self.server.memory:
            raise ValidationError('the requested memory size is not available on the specified server')
        

    @property
    def uid(self):
        return 30000+self.pk

    @property
    def hostname(self):
        h = ''
        allowed = string.ascii_letters + string.digits + '.-'
        for char in self.name:
            if char in allowed:
                h += char
            else:
                h += '-'
        return h

    @property
    def ip(self):
        # skip the first address as it is always 10.0.0.1
        addr = self.pk + 1
        addr0 = 0x0a000000;
        return ipaddress.IPv4Address(addr0 | (addr & 0x00ffffff))

    @property
    def munix(self):
        return int(time.mktime(self.mtime.timetuple()))

    @property
    def ssh_keys(self):
        # try to generate a clean list of ssh keys
        cleaned = self.ssh_keys_raw.replace('\r', '\n').replace('\n\n', '\n')
        return self.ssh_keys_raw.split('\n')

    @property
    def quota(self):
        return self.storage * (1024*1024)

    @property
    def memory_limit_in_bytes(self):
        return self.memory * (1024*1024)

"""
domains are mapped to customers, each container of the customer
can subscribe to them
"""
class Domain(models.Model):
    name = models.CharField(max_length=255)
    customer = models.ForeignKey(Customer)

    ctime = models.DateTimeField(auto_now_add=True)
    mtime = models.DateTimeField(auto_now=True)

    uuid = models.CharField(max_length=36, default=generate_uuid,unique=True)

    def __unicode__(self):
        return self.name
